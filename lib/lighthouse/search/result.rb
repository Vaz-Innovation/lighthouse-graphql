# frozen_string_literal: true

# A search an engine outside the database answers: the page of records it found
# and its total, in relevance order. It is the list @paginate pages
# (Pagination::List), and @all reads whole. The engine is asked once per page,
# whose response holds the total too, so a page costs one request even when
# the client selects `paginatorInfo`.
#
# An engine pages no further than its result window (Elasticsearch's and
# OpenSearch's index.max_result_window): a window that runs past it is cut at
# its end, and one that starts past it is a client error.
class Lighthouse::Search::Result
  include Lighthouse::GraphQL::Pagination::List

  # The result window of an adapter that does not tell it (`result_window(query)`):
  # Elasticsearch's and OpenSearch's default index.max_result_window.
  MAX_WINDOW = 10_000

  def initialize(adapter, query)
    @adapter = adapter
    @query = query
  end

  attr_reader :query

  # The records at `offset`, `limit` of them, those within the result window.
  def window(offset, limit)
    return [] if limit.zero?

    records, @count = @adapter.page(@query, offset: offset, limit: within_window(offset, limit))
    records
  end

  # How many records match: the total the last page came with, else a request for no records.
  def count
    @count ||= @adapter.page(@query, offset: 0, limit: 0).last
  end

  # What @all returns: `first` records from `offset`, else all of them, up to the result window.
  def records(first: nil, offset: nil)
    window(offset || 0, first || result_window)
  end

  # How many of the matches the engine pages through.
  def result_window
    @result_window ||= @adapter.respond_to?(:result_window) ? @adapter.result_window(@query) : MAX_WINDOW
  end

  private

  def within_window(offset, limit)
    return [limit, result_window - offset].min if offset < result_window

    raise ::GraphQL::ExecutionError,
          "The search reads no further than its first #{result_window} matches (the index.max_result_window of " \
          "#{@query.model.name}), so offset #{offset} is past them. Narrow the search instead."
  end
end
