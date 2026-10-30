# frozen_string_literal: true

# A search an engine outside the database answers: the page of records it found
# and its total, in relevance order. It is the list @paginate pages
# (Pagination::List), and @all reads whole. The engine is asked once per page,
# whose response holds the total too, so a page costs one request even when
# the client selects `paginatorInfo`.
class Lighthouse::Search::Result
  include Lighthouse::GraphQL::Pagination::List

  # @all without `first` reads this many, the most Elasticsearch and OpenSearch
  # return by default (index.max_result_window).
  MAX_WINDOW = 10_000

  def initialize(adapter, query)
    @adapter = adapter
    @query = query
  end

  attr_reader :query

  # The records at `offset`, `limit` of them.
  def window(offset, limit)
    return [] if limit.zero?

    records, @count = @adapter.page(@query, offset: offset, limit: limit)
    records
  end

  # How many records match: the total the last page came with, else a request for no records.
  def count
    @count ||= @adapter.page(@query, offset: 0, limit: 0).last
  end

  # What @all returns: `first` records from `offset`, else all of them (up to MAX_WINDOW).
  def records(first: nil, offset: nil)
    window(offset || 0, first || MAX_WINDOW)
  end
end
