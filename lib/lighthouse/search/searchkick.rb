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
# model must index its soft-delete column, the one Support::SoftDeletes filters
# the database on (paranoia's, discard's, Config.soft_deletes', else `deleted_at`),
# the one source of it: ONLY keeps the records with a value in it
# (other than paranoia's sentinel), WITHOUT the ones without, and WITH both, if
# the index holds trashed records at all.
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

  def initialize
    @indexed = {}
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
  # `max_result_window:` (in `searchkick` or its index `settings:`, whatever their
  # keys), a billion with `deep_paging: true`, else the engines' default, 10,000.
  # nil for another index `within:` names, whose settings the model does not
  # tell: the engine's own refusal stands (#page).
  def result_window(query)
    return nil unless own_index?(query)

    options = ::ActiveSupport::HashWithIndifferentAccess.new(query.model.searchkick_options)
    options[:max_result_window] || settings_window(options[:settings] || {}) ||
      (options[:deep_paging] ? DEEP_PAGING_WINDOW : Lighthouse::Search::Result::MAX_WINDOW)
  end

  private

  # Does the search read the model's own index, whose settings the model tells?
  def own_index?(query) = query.index.nil? || query.index == query.model.searchkick_index&.name

  # The window the index `settings:` set, nested or flat.
  def settings_window(settings) = settings.dig(:index, :max_result_window) || settings[:'index.max_result_window']

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

    column, kept = trashed_column(query.model)
    require_indexed!(query.model, column)
    case query.trashed
    when :only then { column.to_sym => { not: kept } }
    when :without then { column.to_sym => kept }
    else {}
    end
  end

  # [the indexed column that marks trashed records, its value for the others]:
  # the soft-delete adapter's (paranoia's, with its sentinel; discard's;
  # Config.soft_deletes'), which the database filters and the records load
  # through too; deleted_at when an app's adapter does not tell.
  def trashed_column(model)
    [Lighthouse::Support::SoftDeletes.column(model) || DEFAULT_TRASHED_COLUMN, Lighthouse::Support::SoftDeletes.kept_value(model)]
  end

  # The index must hold the column, or the filter would match nothing (or everything).
  def require_indexed!(model, column)
    indexed = indexed_columns(model)
    return if indexed.nil? || indexed.include?(column.to_s)

    raise ::GraphQL::ExecutionError, "#{model.name}.search_data does not index #{column}, which @trashed filters the search on."
  end

  # What `search_data` holds, or nil when it cannot run on a blank record. Read
  # once per model class: a class code reloading makes is read again.
  def indexed_columns(model)
    model_class, columns = @indexed[model.name]
    return columns if model_class.equal?(model)

    columns = begin
      model.new.search_data.keys.map(&:to_s)
    rescue StandardError
      nil
    end
    @indexed[model.name] = [model, columns]
    columns
  end
end
