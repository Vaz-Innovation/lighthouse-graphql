# frozen_string_literal: true

# Searchkick (Elasticsearch / OpenSearch), outside the database: the filters the
# client sends are translated into Searchkick's `where:`, and what comes back are
# Active Record records in relevance order, so nested fields and the Dataloader
# work on them as usual. One request returns a page and the total, which is
# exact: Elasticsearch and OpenSearch 7+ stop counting at 10,000 unless asked
# (`track_total_hits`), so Lighthouse asks, unless the app's `body_options:` say otherwise.
#
# `within:` names the index (`index_name:`), the model's own by default.
#
# Searchkick indexes what the model's `search_data` says. For @trashed the
# model must index its soft-delete column (`deleted_at`, or paranoia's / discard's;
# `trashed_column:` names another): ONLY keeps the records with a value in it, WITHOUT
# the ones without, and WITH both, if the index holds trashed records at all.
# Searchkick loads what it finds through the model, whose default scope may hide
# trashed records (paranoia's): with ONLY and WITH they load past it.
#
# The records load through the model's `search_results` scope too, if it has one
# (Lighthouse::Search), then the app's own `scope_results:` (from @builder).
#
# The gem is not a dependency of Lighthouse: the adapter is used when the
# model calls `searchkick`.
class Lighthouse::Search::Searchkick
  DEFAULT_TRASHED_COLUMN = 'deleted_at'

  # The result window of a model with `searchkick deep_paging: true`, as Searchkick sets it.
  DEEP_PAGING_WINDOW = 1_000_000_000

  def initialize(trashed_column: nil)
    @trashed_column = trashed_column&.to_s
  end

  def searchable?(model, _index = nil)
    !!(defined?(::Searchkick) && model.respond_to?(:searchkick_index))
  end

  def relational? = false

  # [the records at `offset`, `limit` of them in relevance order, the total that match].
  def page(query, offset:, limit:)
    response = query.model.searchkick_search(query.term, **search_options(query), offset: offset, limit: limit)
    [response.to_a, response.total_count]
  rescue StandardError => e
    raise unless past_window?(e)

    # The index's window is smaller than the model's options say: set on the server.
    raise ::GraphQL::ExecutionError, "The search reads no further than the index.max_result_window of #{query.model.name}. Narrow the search instead."
  end

  # How many of the matches the model's index pages through (Search::Result): its
  # `max_result_window:` (in `searchkick` or its index `settings:`), a billion
  # with `deep_paging: true`, else the engines' default, 10,000.
  def result_window(query)
    options = query.model.searchkick_options
    options[:max_result_window] || options.dig(:settings, :index, :max_result_window) ||
      (options[:deep_paging] ? DEEP_PAGING_WINDOW : Lighthouse::Search::Result::MAX_WINDOW)
  end

  private

  def past_window?(error)
    defined?(::Searchkick::InvalidQueryError) && error.is_a?(::Searchkick::InvalidQueryError) && error.message.include?('max_result_window')
  end

  def search_options(query)
    options = query.options.dup
    options[:where] = (options[:where] || {}).merge(filters(query))
    options[:index_name] = query.index if query.index
    options[:load] = true unless options.key?(:load)
    options[:body_options] = { track_total_hits: true }.merge(options[:body_options] || {})
    loading = results_scope(query, options[:scope_results])
    options[:scope_results] = loading if loading
    options
  end

  # What Searchkick loads the records it found through (`scope_results:`): past
  # the default scope that hides trashed ones when @trashed asks for them, the
  # model's `search_results` scope, then the app's own; nil for the model alone.
  def results_scope(query, own)
    trashed = %i[only with].include?(query.trashed)
    guarded = Lighthouse::Search.results_scope?(query.model)
    return own unless trashed || guarded

    lambda do |records|
      records = records.all
      records = Lighthouse::Support::SoftDeletes.with_trashed(records) if trashed
      records = Lighthouse::Search.results(records)
      own ? own.call(records) : records
    end
  end

  def filters(query)
    query.wheres.transform_keys(&:to_sym).merge(trashed_filter(query))
  end

  def trashed_filter(query)
    return {} unless query.trashed

    column = trashed_column(query.model)
    require_indexed!(query.model, column)
    case query.trashed
    when :only then { column.to_sym => { not: nil } }
    when :without then { column.to_sym => nil }
    else {}
    end
  end

  def trashed_column(model)
    @trashed_column || (model.respond_to?(:discard_column) && model.discard_column) ||
      (model.respond_to?(:paranoia_column) && model.paranoia_column) || DEFAULT_TRASHED_COLUMN
  end

  # The index must hold the column, or the filter would match nothing (or everything).
  def require_indexed!(model, column)
    indexed = indexed_columns(model)
    return if indexed.nil? || indexed.include?(column.to_s)

    raise ::GraphQL::ExecutionError, "#{model.name}.search_data does not index #{column}, which @trashed filters the search on."
  end

  # What `search_data` holds, or nil when it cannot run on a blank record.
  def indexed_columns(model)
    model.new.search_data.keys.map(&:to_s)
  rescue StandardError
    nil
  end
end
