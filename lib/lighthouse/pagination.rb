# frozen_string_literal: true

require 'base64'

# Runtime side of pagination — @paginate, and @hasMany / @belongsToMany /
# @morphMany / @morphToMany with `type:` — as PHP Lighthouse does it:
#
#   PAGINATOR   first/page → { paginatorInfo: PaginatorInfo!, data }
#   SIMPLE      first/page → { paginatorInfo: SimplePaginatorInfo!, data } (no total)
#   CONNECTION  first/after → { pageInfo: PageInfo!, edges { cursor node } }
#
# Cursors are base64 of the 1-based position, PHP Lighthouse's format. The
# schema side (types, arguments) is Directives::PaginationManipulator.
#
# A page reads its rows and total from a list: a RelationList queries one
# relation (or array), a BatchedList loads them through the Dataloader for
# every parent of a paginated relation at once.
module Lighthouse::GraphQL::Pagination
  TYPES = %w[PAGINATOR SIMPLE CONNECTION].freeze

  module_function

  # `relation`: a relation, an array or a list (BatchedList).
  # `limits`: { default_count:, max_count: } — max_count may be :unlimited.
  def paginate(relation, type, args, limits = {})
    first = args[:first] || limits[:default_count] || Lighthouse::Config.pagination_default_count
    validate!(first, limits.fetch(:max_count) { Lighthouse::Config.pagination_max_count })

    list = relation.is_a?(List) ? relation : RelationList.new(relation)
    case type
    when 'SIMPLE' then simple(list, first, page(args))
    when 'CONNECTION' then connection(list, first, offset_after(args[:after]))
    else paginator(list, first, page(args))
    end
  end

  # Where a page's rows and total come from.
  module List; end

  # A window of records that may hold fewer records than positions: a search
  # whose hits did not all load (Search::Result). Each record keeps its position
  # in the whole list, and `covered` tells how many positions the window spans,
  # so pages and cursors follow positions: the next page starts after a dropped
  # hit, never before it, and no record shows twice. A plain array's records
  # hold the positions from the window's offset on.
  class Window < Array
    attr_reader :positions, :covered

    def initialize(records, positions, covered)
      super(records)
      @positions = positions
      @covered = covered
    end
  end

  # The positions of a window's records, from `offset`.
  def positions(rows, offset) = rows.is_a?(Window) ? rows.positions : (offset...(offset + rows.size)).to_a

  # How many positions a window spans.
  def covered(rows) = rows.is_a?(Window) ? rows.covered : rows.size

  class RelationList
    include List

    def initialize(relation)
      @relation = relation
    end

    def window(offset, limit) = Lighthouse::GraphQL::Pagination.window(@relation, offset, limit)
    def count = Lighthouse::GraphQL::Pagination.count(@relation)
  end

  # One parent's page of a relation batched with its siblings' (RelationBatch).
  class BatchedList
    include List

    def initialize(batch, owner, dataloader)
      @batch = batch
      @owner = owner
      @dataloader = dataloader
    end

    def window(offset, limit)
      return [] if limit.zero?

      @dataloader.with(Lighthouse::GraphQL::DataloaderSources::RelationPageLoader, @batch, offset, limit).load(@owner)
    end

    def count
      @dataloader.with(Lighthouse::GraphQL::DataloaderSources::RelationCountLoader, @batch).load(@owner)
    end
  end

  def validate!(first, max_count)
    raise ::GraphQL::ExecutionError, 'Pagination requires the `first` argument.' if first.nil?
    raise ::GraphQL::ExecutionError, "Requested pagination amount must be non-negative, got #{first}." if first.negative?
    return if max_count.nil? || max_count == :unlimited || first <= max_count

    raise ::GraphQL::ExecutionError,
          "Maximum number of #{max_count} requested items exceeded, got #{first}. Fetch smaller chunks."
  end

  def page(args)
    [args[:page] || 1, 1].max
  end

  def paginator(list, per_page, page)
    Paginator.new(list, per_page, page)
  end

  # Fetches one extra position to tell whether there is a next page, instead of counting.
  def simple(list, per_page, page)
    offset = (page - 1) * per_page
    rows = list.window(offset, per_page + 1)
    all_positions = positions(rows, offset)
    kept = rows.each_index.select { |index| all_positions[index] < offset + per_page }
    items = kept.map { |index| rows[index] }
    {
      'paginatorInfo' => item_range(items, page, per_page, kept.map { |index| all_positions[index] })
                         .merge('hasMorePages' => covered(rows) > per_page),
      'data' => items
    }
  end

  def connection(list, first, offset)
    Connection.new(list, first, offset)
  end

  # A page whose total is only counted when the client selects
  # paginatorInfo / pageInfo, so a query for `data` alone costs one query.
  # Marshals with the total resolved, so @cache can store it.
  class LazyPage
    def initialize(list, items)
      super()
      @list = list
      @items = items
    end

    # The records on the page, for @lazyLoad.
    attr_reader :items

    def marshal_dump
      [info, @items]
    end

    def marshal_load((info, items))
      @info = info
      @items = items
    end

    private

    def total
      @total ||= @list.count
    end

    # How many records a page can reach: the total, but a search's only within
    # its engine's result window (Search::Result#reachable). Pages are counted
    # from it, so no page is announced that would then be refused.
    def reachable
      @reachable ||= @list.respond_to?(:reachable) ? @list.reachable : total
    end
  end

  class Paginator < LazyPage
    def initialize(list, per_page, page)
      super(list, list.window((page - 1) * per_page, per_page))
      @per_page = per_page
      @page = page
    end

    def data = @items

    def paginatorInfo = info # rubocop:disable Naming/MethodName -- the GraphQL field's name, which the default resolver reads

    def info
      @info ||= begin
        last_page = @per_page.zero? ? 0 : [(reachable.to_f / @per_page).ceil, 1].max
        positions = Lighthouse::GraphQL::Pagination.positions(@items, (@page - 1) * @per_page)
        Lighthouse::GraphQL::Pagination.item_range(@items, @page, @per_page, positions)
                                       .merge('hasMorePages' => @page < last_page, 'lastPage' => last_page, 'total' => total)
      end
    end
  end

  class Connection < LazyPage
    def initialize(list, first, offset)
      super(list, list.window(offset, first))
      @first = first
      @offset = offset
    end

    # A cursor is a record's position in the whole list, 1-based.
    def edges
      cursors.zip(@items).map { |cursor, node| { 'cursor' => cursor, 'node' => node } }
    end

    def pageInfo = info # rubocop:disable Naming/MethodName -- the GraphQL field's name, which the default resolver reads

    # The start and end cursors are the first and last edge's, as Relay's. A page
    # whose hits all failed to load has no edge, but its end cursor is past the
    # positions it spans, so the client walks on to the next page.
    def info
      covered = Lighthouse::GraphQL::Pagination.covered(@items)
      past = Lighthouse::GraphQL::Pagination.encode_cursor(@offset + covered) unless covered.zero?
      @info ||= {
        'hasNextPage' => @offset + covered < reachable,
        'hasPreviousPage' => @offset.positive?,
        'startCursor' => cursors.first,
        'endCursor' => cursors.last || past,
        'total' => total,
        'count' => @items.size,
        'currentPage' => @first.zero? ? 1 : (@offset / @first) + 1,
        'lastPage' => @first.zero? ? 0 : [(reachable.to_f / @first).ceil, 1].max
      }
    end

    def cursors
      @cursors ||= Lighthouse::GraphQL::Pagination.positions(@items, @offset).map { |position| Lighthouse::GraphQL::Pagination.encode_cursor(position + 1) }
    end

    def marshal_dump
      [info, @items, @offset]
    end

    def marshal_load((info, items, offset))
      super([info, items])
      @offset = offset
    end
  end

  # firstItem and lastItem are the 1-based positions of the page's first and
  # last record (`positions`, 0-based, of a Window whose hits did not all load).
  def item_range(items, page, per_page, positions = nil)
    positions ||= (0...items.size).map { |index| ((page - 1) * per_page) + index }
    {
      'count' => items.size,
      'currentPage' => page,
      'firstItem' => positions.first&.+(1),
      'lastItem' => positions.last&.+(1),
      'perPage' => per_page
    }
  end

  def window(relation, offset, limit)
    return [] if limit.zero?
    return Array(relation)[offset, limit] || [] unless relation.respond_to?(:offset)

    stable_order(relation).offset(offset).limit(limit).to_a
  end

  # The relation, its ORDER BY ending with the primary key. Pages are cut by
  # position (an OFFSET, or a row number per parent), and rows the order ties
  # (posts with the same created_at), or a relation with no order at all, may
  # come back in another order on the next page's query: a row then shows on
  # two pages, or on none. PHP Lighthouse leaves the order as it is. A grouped
  # relation is left alone: its key may not be in the GROUP BY.
  def stable_order(relation)
    return relation unless relation.respond_to?(:klass) && relation.klass.primary_key && relation.group_values.empty?

    table = relation.klass.arel_table
    missing = Array(relation.klass.primary_key).reject { |key| ordered_by?(relation, table.name, key) }
    missing.empty? ? relation : relation.order(*missing.map { |key| table[key].asc })
  end

  # Does the relation's ORDER BY name `table`.`key`, or `key` alone?
  def ordered_by?(relation, table_name, key)
    column = /(?:\A|[^\w."`\]])(?:["`\[]?#{Regexp.escape(table_name)}["`\]]?\.)?["`\[]?#{Regexp.escape(key)}["`\]]?(?:\s|,|\z)/i
    relation.order_values.any? { |order| (order.respond_to?(:to_sql) ? order.to_sql : order.to_s).match?(column) }
  end

  def count(relation)
    return Array(relation).size unless relation.respond_to?(:unscope)

    relation.unscope(:order, :limit, :offset).count
  end

  def encode_cursor(position)
    Base64.strict_encode64(position.to_s)
  end

  # The number of items the `after` cursor points past (0 for none or garbage).
  def offset_after(cursor)
    return 0 if cursor.blank?

    Integer(Base64.strict_decode64(cursor), 10)
  rescue ArgumentError
    0
  end
end
