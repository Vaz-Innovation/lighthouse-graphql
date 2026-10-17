# frozen_string_literal: true

require 'base64'

module Lighthouse
  module GraphQL
    # Runtime side of pagination — @paginate, and @hasMany / @belongsToMany /
    # @morphMany / @morphToMany with `type:` — as PHP Lighthouse does it:
    #
    #   PAGINATOR   first/page → { paginatorInfo: PaginatorInfo!, data }
    #   SIMPLE      first/page → { paginatorInfo: SimplePaginatorInfo!, data } (no total)
    #   CONNECTION  first/after → { pageInfo: PageInfo!, edges { cursor node } }
    #
    # Cursors are base64 of the 1-based position, PHP Lighthouse's format. The
    # schema side (types, arguments) is Directives::PaginationManipulator.
    module Pagination
      TYPES = %w[PAGINATOR SIMPLE CONNECTION].freeze

      module_function

      # `limits`: { default_count:, max_count: } — max_count may be :unlimited.
      def paginate(relation, type, args, limits = {})
        first = args[:first] || limits[:default_count] || Lighthouse::Config.pagination_default_count
        validate!(first, limits.fetch(:max_count) { Lighthouse::Config.pagination_max_count })

        case type
        when 'SIMPLE' then simple(relation, first, page(args))
        when 'CONNECTION' then connection(relation, first, offset_after(args[:after]))
        else paginator(relation, first, page(args))
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

      def paginator(relation, per_page, page)
        Paginator.new(relation, per_page, page)
      end

      # Fetches one extra row to tell whether there is a next page, instead of counting.
      def simple(relation, per_page, page)
        rows = window(relation, (page - 1) * per_page, per_page + 1)
        items = rows.first(per_page)
        {
          'paginatorInfo' => item_range(items, page, per_page).merge('hasMorePages' => rows.size > per_page),
          'data' => items
        }
      end

      def connection(relation, first, offset)
        Connection.new(relation, first, offset)
      end

      # A page whose total is only counted when the client selects
      # paginatorInfo / pageInfo, so a query for `data` alone costs one query.
      # Marshals with the total resolved, so @cache can store it.
      class LazyPage
        def marshal_dump
          [info, @items]
        end

        def marshal_load((info, items))
          @info = info
          @items = items
        end

        private

        def total
          @total ||= Pagination.count(@relation)
        end
      end

      class Paginator < LazyPage
        def initialize(relation, per_page, page)
          @relation = relation
          @per_page = per_page
          @page = page
          @items = Pagination.window(relation, (page - 1) * per_page, per_page)
        end

        def data = @items

        def paginatorInfo = info

        def info
          @info ||= begin
            last_page = @per_page.zero? ? 0 : [(total.to_f / @per_page).ceil, 1].max
            Pagination.item_range(@items, @page, @per_page)
                      .merge('hasMorePages' => @page < last_page, 'lastPage' => last_page, 'total' => total)
          end
        end
      end

      class Connection < LazyPage
        def initialize(relation, first, offset)
          @relation = relation
          @first = first
          @offset = offset
          @items = Pagination.window(relation, offset, first)
        end

        def edges
          @items.each_with_index.map { |node, i| { 'cursor' => Pagination.encode_cursor(@offset + i + 1), 'node' => node } }
        end

        def pageInfo = info

        def info
          @info ||= {
            'hasNextPage' => @offset + @items.size < total,
            'hasPreviousPage' => @offset.positive?,
            'startCursor' => @items.empty? ? nil : Pagination.encode_cursor(@offset + 1),
            'endCursor' => @items.empty? ? nil : Pagination.encode_cursor(@offset + @items.size),
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
        return 0 if cursor.nil? || cursor.empty?

        Integer(Base64.strict_decode64(cursor), 10)
      rescue ArgumentError
        0
      end
    end
  end
end
