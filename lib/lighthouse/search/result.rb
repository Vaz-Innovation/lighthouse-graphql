# frozen_string_literal: true

# A search an engine outside the database answers: the page of records it found
# and its total, in relevance order. It is the list @paginate pages
# (Pagination::List), and @all reads whole. The engine is asked once per page,
# whose response holds the total too, so a page costs one request even when
# the client selects `paginatorInfo`. Each field's search is its own Result, and
# asks the engine itself: one is never shared between fields or requests, nor
# kept in the query's context. Within one resolution of a field, the search
# @canQuery checked serves the page (`Result.serving`), from the hits it read and
# checked: a record the index gains in between is never answered unchecked.
#
# The total is exact, every match counted (Search::Searchkick asks for it): pages,
# truncation and @canQuery's check of every hit rely on it.
#
# An engine pages no further than its result window (Elasticsearch's and
# OpenSearch's index.max_result_window): a window that runs past it is cut at
# its end, and one that starts past it is a client error. When the adapter does
# not know the window (`result_window` nil), the engine refuses on its own.
#
# The engine's requests fail as the field's filters do (Support::Failures),
# whenever they run: an engine's error is reported to Config.on_error.
class Lighthouse::Search::Result
  include Lighthouse::GraphQL::Pagination::List

  # The result window of an adapter that does not tell it (`result_window(query)`):
  # Elasticsearch's and OpenSearch's default index.max_result_window.
  MAX_WINDOW = 10_000

  # The most records one read asks for, whatever the window (a billion with
  # Searchkick's `deep_paging`): @all, and the records @canQuery checks.
  READ_LIMIT = 10_000

  # The fiber-local key of the search @canQuery checked, while the field it checks resolves.
  CHECKED = :lighthouse_checked_search

  # The block (one resolution of a field: CanQueryDirectiveResolver), in which a
  # search of the same field (`checked`) is the `result` @canQuery read: the
  # Enhancer answers it, whose hits serve the page. Fiber-local, so neither
  # another field, resolving meanwhile in another fiber, nor another query sees it.
  def self.serving(result)
    previous = Thread.current[CHECKED]
    Thread.current[CHECKED] = result
    yield
  ensure
    Thread.current[CHECKED] = previous
  end

  # The search @canQuery checked in this resolution, when it is this one: the same
  # field, adapter, model, term, index and conditions; else nil.
  def self.checked(adapter, query, field)
    checked = Thread.current[CHECKED]
    checked if checked.is_a?(self) && checked.same_search?(adapter, query, field)
  end

  # `context`: the query's, to which the engine's errors are reported. `field`:
  # "Type.field", whose search this is.
  def initialize(adapter, query, context: nil, field: nil)
    @adapter = adapter
    @query = query
    @context = context
    @field = field
  end

  attr_reader :query

  # The engine's name, for errors: Searchkick.
  def adapter_name = @adapter.class.name.demodulize

  # The records at `offset`, `limit` positions of them, within the result window:
  # a Pagination::Window, whose records keep their engine positions. The adapter
  # answers one entry per hit, nil for a hit that did not load (the model's
  # scopes, a record gone from the database), so pages and cursors follow the
  # engine's positions, and none shows a record twice.
  def window(offset, limit)
    return [] if limit.zero?

    limit = within_window(offset, limit)
    entries = @checked ? (@checked[offset, limit] || []) : request(offset, limit)
    loaded = entries.each_index.reject { |index| entries[index].nil? }
    Lighthouse::GraphQL::Pagination::Window.new(entries.compact, loaded.map { |index| offset + index }, entries.size)
  end

  # How many records match: the total the last page came with, else a request for no records.
  def count
    request(0, 0) unless @count
    @count
  end

  # What @all returns: `first` records from `offset` (every one when nil), of
  # which one read takes READ_LIMIT at most, within the result window.
  # `truncated?` tells when that answered fewer than asked while more match.
  def records(first: nil, offset: nil)
    offset ||= 0
    found = window(offset, [first || READ_LIMIT, READ_LIMIT].min)
    read = Lighthouse::GraphQL::Pagination.covered(found)
    @truncated = (first.nil? || read < first) && count > offset + read
    found
  end

  # Did the last `records` answer fewer matches than asked for, while more match
  # (READ_LIMIT, the result window)?
  def truncated? = @truncated == true

  # What @find returns: the one record the search finds, or nil. More than one
  # match, as the engine counts them, is an error, as in PHP Lighthouse.
  def only_record
    found = window(0, 1)
    raise ::GraphQL::ExecutionError, 'The query returned more than one result.' if count > 1

    found.first
  end

  # What @first returns: the best match that loads, or nil. A best hit that does
  # not load (the model's scopes, a record gone from the database) yields to the
  # next one, read within the result window and READ_LIMIT.
  def first_record
    found = window(0, 1)
    return found.first if found.any? || count <= 1

    window(0, [reachable, READ_LIMIT].min).first
  end

  # How many matches a page can reach: the total, within the result window.
  def reachable = result_window ? [count, result_window].min : count

  # Every record the search finds that a page can reach, for @canQuery to check:
  # one request, of READ_LIMIT records at most, whose hits then serve every page
  # of this Result, and no other request. A search that finds more within the
  # result window is a client error, as a page could reach a record not checked.
  def every_record
    found = window(0, READ_LIMIT)
    unless reachable <= READ_LIMIT
      raise ::GraphQL::ExecutionError,
            "@canQuery checks every record the search finds, at most #{READ_LIMIT}, and this one finds #{reachable}. Narrow the search."
    end

    @checked ||= @last_entries
    found
  end

  # Is it the search of `field` that `adapter` runs for `query`? Its options aside,
  # which may hold an @builder's procs, made again for each search.
  def same_search?(adapter, query, field)
    @adapter.equal?(adapter) && @field == field && query.model.equal?(@query.model) && query.models == @query.models &&
      [query.term, query.index, query.wheres, query.trashed] == [@query.term, @query.index, @query.wheres, @query.trashed]
  end

  # How many of the matches the engine pages through; nil when the adapter cannot tell.
  def result_window
    return @result_window if defined?(@result_window)

    @result_window = Lighthouse::Support::Failures.strictly(@context) do
      @adapter.respond_to?(:result_window) ? @adapter.result_window(@query) : MAX_WINDOW
    end
  end

  private

  # The engine's entries at `offset`, `limit` of them; its total, which must be a count.
  def request(offset, limit)
    Lighthouse::Support::Failures.strictly(@context) do
      entries, total = @adapter.page(@query, offset: offset, limit: limit)
      unless total.is_a?(Integer)
        raise Lighthouse::DefinitionError, "@search: #{adapter_name} answered #{total.inspect} for the total, not the count of every match"
      end

      @count = total
      @last_entries = entries
    end
  end

  def within_window(offset, limit)
    return limit if result_window.nil?
    return [limit, result_window - offset].min if offset < result_window

    raise ::GraphQL::ExecutionError,
          "The search reads no further than its first #{result_window} matches (the index.max_result_window of " \
          "#{@query.name}), so offset #{offset} is past them. Narrow the search instead."
  end
end
