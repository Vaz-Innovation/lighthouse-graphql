# frozen_string_literal: true

# A search an engine outside the database answers: the page of records it found
# and its total, in relevance order. It is the list @paginate pages
# (Pagination::List), and @all reads whole. The engine is asked once per page,
# whose response holds the total too, so a page costs one request even when
# the client selects `paginatorInfo`.
#
# An engine pages no further than its result window (Elasticsearch's and
# OpenSearch's index.max_result_window): a window that runs past it is cut at
# its end, and one that starts past it is a client error. When the adapter does
# not know the window (`result_window` nil), the engine refuses on its own.
class Lighthouse::Search::Result
  include Lighthouse::GraphQL::Pagination::List

  # The result window of an adapter that does not tell it (`result_window(query)`):
  # Elasticsearch's and OpenSearch's default index.max_result_window.
  MAX_WINDOW = 10_000

  # The most records a read without `first` asks for, whatever the window (a
  # billion with Searchkick's `deep_paging`): @all without `first`, and the
  # records @canQuery checks.
  READ_LIMIT = 10_000

  def initialize(adapter, query)
    @adapter = adapter
    @query = query
  end

  attr_reader :query

  # The records at `offset`, `limit` positions of them, within the result window:
  # a Pagination::Window, whose records keep their engine positions. The adapter
  # answers one entry per hit, nil for a hit that did not load (the model's
  # scopes, a record gone from the database), so pages and cursors follow the
  # engine's positions, and none shows a record twice.
  def window(offset, limit)
    return [] if limit.zero?

    limit = within_window(offset, limit)
    entries = fetched(offset, limit) || fetch(offset, limit)
    loaded = entries.each_index.reject { |index| entries[index].nil? }
    Lighthouse::GraphQL::Pagination::Window.new(entries.compact, loaded.map { |index| offset + index }, entries.size)
  end

  # How many records match: the total the last page came with, else a request for no records.
  def count
    @count ||= @adapter.page(@query, offset: 0, limit: 0).last
  end

  # What @all returns: `first` records from `offset`, else READ_LIMIT of them at
  # most (`truncated?` tells when that left matches unread); within the result
  # window either way.
  def records(first: nil, offset: nil)
    offset ||= 0
    found = window(offset, first || READ_LIMIT)
    @truncated = first.nil? && reachable > offset + Lighthouse::GraphQL::Pagination.covered(found)
    found
  end

  # Did the last read without `first` leave matches a page could reach unread?
  def truncated? = @truncated == true

  # How many matches a page can reach: the total, within the result window.
  def reachable = result_window ? [count, result_window].min : count

  # Every record the search finds that a page can reach, for @canQuery to check:
  # one request, of READ_LIMIT records at most. A search that finds more within
  # the result window is a client error, as a page could reach a record not checked.
  def every_record
    found = records
    return found if reachable <= READ_LIMIT

    raise ::GraphQL::ExecutionError,
          "@canQuery checks every record the search finds, at most #{READ_LIMIT}, and this one finds #{reachable}. Narrow the search."
  end

  # How many of the matches the engine pages through; nil when the adapter cannot tell.
  def result_window
    return @result_window if defined?(@result_window)

    @result_window = @adapter.respond_to?(:result_window) ? @adapter.result_window(@query) : MAX_WINDOW
  end

  private

  # The engine's entries at `offset`, `limit` of them, kept for a later window.
  def fetch(offset, limit)
    entries, @count = @adapter.page(@query, offset: offset, limit: limit)
    @fetched = [offset, entries, entries.size < limit]
    entries
  end

  # The entries at `offset`, `limit` of them, from an earlier request that holds
  # them (or held every hit from its offset on), as @canQuery's read of every hit
  # holds the page the field then answers; nil when none does.
  def fetched(offset, limit)
    start, entries, every = @fetched
    return nil unless start && offset >= start && (offset + limit <= start + entries.size || every)

    entries[(offset - start), limit] || []
  end

  def within_window(offset, limit)
    return limit if result_window.nil?
    return [limit, result_window - offset].min if offset < result_window

    raise ::GraphQL::ExecutionError,
          "The search reads no further than its first #{result_window} matches (the index.max_result_window of " \
          "#{@query.model.name}), so offset #{offset} is past them. Narrow the search instead."
  end
end
