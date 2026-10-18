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

  # Fetches one extra row to tell whether there is a next page, instead of counting.
  def simple(list, per_page, page)
    rows = list.window((page - 1) * per_page, per_page + 1)
    items = rows.first(per_page)
    {
      'paginatorInfo' => item_range(items, page, per_page).merge('hasMorePages' => rows.size > per_page),
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
        last_page = @per_page.zero? ? 0 : [(total.to_f / @per_page).ceil, 1].max
        Lighthouse::GraphQL::Pagination.item_range(@items, @page, @per_page)
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

    def edges
      @items.each_with_index.map { |node, i| { 'cursor' => Lighthouse::GraphQL::Pagination.encode_cursor(@offset + i + 1), 'node' => node } }
    end

    def pageInfo = info # rubocop:disable Naming/MethodName -- the GraphQL field's name, which the default resolver reads

    def info
      @info ||= {
        'hasNextPage' => @offset + @items.size < total,
        'hasPreviousPage' => @offset.positive?,
        'startCursor' => @items.empty? ? nil : Lighthouse::GraphQL::Pagination.encode_cursor(@offset + 1),
        'endCursor' => @items.empty? ? nil : Lighthouse::GraphQL::Pagination.encode_cursor(@offset + @items.size),
        'total' => total,
        'count' => @items.size,
        'currentPage' => @first.zero? ? 1 : (@offset / @first) + 1,
        'lastPage' => @first.zero? ? 0 : [(total.to_f / @first).ceil, 1].max
      }
    end

    def marshal_dump
      [info, @items, @offset]
    end

    def marshal_load((info, items, offset))
      super([info, items])
      @offset = offset
    end
  end

  def item_range(items, page, per_page)
    first_item = items.empty? ? nil : ((page - 1) * per_page) + 1
    {
      'count' => items.size,
      'currentPage' => page,
      'firstItem' => first_item,
      'lastItem' => first_item && (first_item + items.size - 1),
      'perPage' => per_page
    }
  end

  def window(relation, offset, limit)
    return [] if limit.zero?
    return Array(relation)[offset, limit] || [] unless relation.respond_to?(:offset)

    relation.offset(offset).limit(limit).to_a
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
