# frozen_string_literal: true

# Searchkick (Elasticsearch / OpenSearch), outside the database: the filters the
# client sends are translated into Searchkick's `where:`, and what comes back are
# Active Record records in relevance order, so nested fields and the Dataloader
# work on them as usual. One request returns a page and the total, which is
# exact: Elasticsearch and OpenSearch 7+ stop counting at 10,000 unless asked
# (`track_total_hits`), so Lighthouse always asks, and an app's `body_options:`
# may not ask otherwise: totals, pages and @canQuery's check of every hit rely on it.
#
# The records load through the database with the filters the engine applied
# that it can apply too (@trashed's, and @eq's on a column of the model), so an
# index that lags the database may leave a record out, never answer one that no
# longer matches.
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
# The records load through the app's own `scope_results:` (from @builder) first,
# then Lighthouse's: the model's default scope (with `unscope: true` too), its
# `search_results` scope, if it has one (Lighthouse::Search), and the filters
# above. An @builder sets only the options that rank or shape the hits
# (Searchkick::Options), never what loads, pages or counts them.
#
# The gem is not a dependency of Lighthouse: the adapter is used when the
# model calls `searchkick`.
class Lighthouse::Search::Searchkick
  DEFAULT_TRASHED_COLUMN = 'deleted_at'

  # The result window of a model with `searchkick deep_paging: true`, as Searchkick sets it.
  DEEP_PAGING_WINDOW = 1_000_000_000

  # `index`: what the engine tells of an index (Searchkick::Index), read and kept.
  def initialize(index: Lighthouse::Search::Searchkick::Index.new)
    @per_model = Lighthouse::Support::Memo.new
    @index = index
  end

  def searchable?(model, _index = nil)
    !!(defined?(::Searchkick) && model.respond_to?(:searchkick_index))
  end

  def relational? = false

  # [one entry per hit at `offset`, `limit` of them, in relevance order: the
  # record, or nil for a hit that did not load; the total that match].
  def page(query, offset:, limit:)
    response = query.model.searchkick_search(query.term, **search_options(query), offset: offset, limit: limit)
    exact_total!(query, response)
    [entries(response), response.total_count]
  rescue StandardError => e
    raise unless past_window?(e)

    # The index's window is smaller than the model's options say: set on the server.
    raise ::GraphQL::ExecutionError, "The search reads no further than the index.max_result_window of #{query.model.name}. Narrow the search instead."
  end

  # How many of the matches the index the search reads pages through
  # (Search::Result): its index.max_result_window, read from the engine
  # (Searchkick::Index). When the settings cannot be read, the model's own index
  # takes the window its options set (`max_result_window:`, in `searchkick` or
  # its index `settings:`, whatever their keys; a billion with `deep_paging:
  # true`), and any index the engines' default, 10,000.
  def result_window(query)
    @index.result_window(query.model, index_name(query)) ||
      (own_index?(query) && options_window(query.model)) || Lighthouse::Search::Result::MAX_WINDOW
  end

  # Why the model cannot be searched as it is, or nil: a default scope (a
  # tenant's, a soft delete's; any, as declared, since what one selects may
  # depend on the request), a search_results scope, or the type condition of an
  # STI subclass that searches its parent's index without Searchkick's
  # `inheritance: true` (which filters the engine by type), needs `search_where`,
  # the engine's `where:` for the same records (`{}` when they narrow nothing).
  # Without it the engine would count, and page through, records that do not
  # load: its totals would include other tenants' matches.
  # Search::FieldCheck asks when the schema is built; a search asks too.
  def model_error(model)
    return nil if model.respond_to?(:search_where)

    narrowing = narrowing(model)
    return nil unless narrowing

    "#{narrowing} narrows what a search loads, which the engine does not apply: its totals and pages would count records that " \
      "do not load. Define #{model.name}.search_where, the engine's `where:` for the same records (`{ tenant_id: Current.tenant_id }`), " \
      'or `{}` when the index holds no other'
  end

  private

  # What narrows the records a search of the model loads, which the engine does not apply; nil when nothing does.
  def narrowing(model)
    return "#{model.name}'s default scope" if Lighthouse::Support::Relations.default_scope?(model)
    return "#{model.name}.search_results" if Lighthouse::Search.results_scope?(model)

    "#{model.name}'s STI type, in #{model.base_class.name}'s index without `inheritance: true`," if untyped_subclass?(model)
  end

  # An STI subclass (its relation has a type condition) whose index Searchkick
  # does not filter by type (`searchkick inheritance: true`).
  def untyped_subclass?(model)
    model.respond_to?(:finder_needs_type_condition?) && model.finder_needs_type_condition? &&
      !searchkick_option(model, :inheritance)
  end

  def searchkick_option(model, name) = ::ActiveSupport::HashWithIndifferentAccess.new(model.searchkick_options)[name]

  # The response's records in their hits' places, nil where one did not load. A
  # record is placed by its hit's index and id, as hits of two indices (Searchkick's
  # `models:`, an `index_name:` list) may share an id.
  def entries(response)
    return response.to_a unless response.respond_to?(:with_hit) && response.respond_to?(:hits)

    loaded = response.with_hit.to_h { |record, hit| [hit_key(hit), record] }
    response.hits.map { |hit| loaded[hit_key(hit)] }
  end

  def hit_key(hit) = [hit['_index'], hit['_id'].to_s]

  # The total must be every match: a total the engine stopped counting at
  # (`"relation": "gte"`) would let a page, or @canQuery's check, miss records.
  def exact_total!(query, response)
    raw = response.response if response.respond_to?(:response)
    total = raw.to_h.dig('hits', 'total') if raw.respond_to?(:to_h)
    return unless total.is_a?(Hash) && total['relation'] && total['relation'] != 'eq'

    raise Lighthouse::DefinitionError,
          "@search on #{query.model.name}: the engine counted #{total['relation']} #{total['value']} matches, not every one, " \
          'which totals, pages and @canQuery need (track_total_hits)'
  end

  # Does the search read the model's own index, whose settings the model tells?
  def own_index?(query) = query.index.nil? || query.index == query.model.searchkick_index&.name

  def index_name(query) = query.index || query.model.searchkick_index&.name

  # The window the model's options set, or nil.
  def options_window(model)
    options = ::ActiveSupport::HashWithIndifferentAccess.new(model.searchkick_options)
    settings = options[:settings] || {}
    options[:max_result_window] || settings.dig(:index, :max_result_window) || settings[:'index.max_result_window'] ||
      (DEEP_PAGING_WINDOW if options[:deep_paging])
  end

  def past_window?(error)
    defined?(::Searchkick::InvalidQueryError) && error.is_a?(::Searchkick::InvalidQueryError) && error.message.include?('max_result_window')
  end

  def search_options(query)
    options = Lighthouse::Search::Searchkick::Options.builder!(query)
    wheres = query.wheres.map { |column, value| { column => value } }
    options[:where] = all_of(options[:where], engine_where(query), *wheres, trashed_filter(query))
    options[:index_name] = query.index if query.index
    options[:load] = true
    options[:body_options] = Lighthouse::Search::Searchkick::Options.counting(options)
    loading = results_scope(query, options[:scope_results])
    options[:scope_results] = loading if loading
    options
  end

  # What Searchkick loads the records it found through (`scope_results:`): the
  # app's own first, then what Lighthouse narrows them to, last, so nothing
  # widens it: the model's default scope when the model loads `unscope: true`
  # (Searchkick loads through `unscoped`), the filters the engine applied that the
  # database can apply too (@trashed's, the @eq ones on a column of the model,
  # with a plain value), so a record the index holds as it was no longer matches,
  # and the model's `search_results` scope; nil for the model alone.
  def results_scope(query, own)
    wheres = Lighthouse::Search::Searchkick::Options.database_wheres(query)
    return own unless own || narrows_load?(query, wheres)

    ->(records) { load_through(own ? own.call(records) : records.all, query, wheres) }
  end

  def load_through(records, query, wheres)
    records = records.merge(query.model.all) if searchkick_option(query.model, :unscope)
    records = Lighthouse::Support::SoftDeletes.filter(records, query.trashed.to_s) if query.trashed
    records = wheres.reduce(records) { |narrowed, (column, value)| narrowed.where(column => value) }
    Lighthouse::Search.results(records)
  end

  def narrows_load?(query, wheres)
    searchkick_option(query.model, :unscope) || query.trashed || wheres.any? || Lighthouse::Search.results_scope?(query.model)
  end

  # The model's search_where, the engine's `where:` for what its default scope and
  # search_results keep, which must leave the soft-delete column to Lighthouse
  # (trashed_filter): a condition on it in search_where could not yield to @trashed.
  def engine_where(query)
    model = query.model
    where = (model.search_where if model.respond_to?(:search_where)).to_h
    column = Lighthouse::Support::SoftDeletes.supported?(model) && trashed_column(model).first.to_s
    return where unless column && names?(where, column)

    raise Lighthouse::DefinitionError,
          "#{model.name}.search_where names #{column}, the column @trashed and Lighthouse filter trashed records on: leave it out"
  end

  # Does the engine condition name `column`, at any depth (`_and`, `_or`, `_not`)?
  def names?(condition, column)
    case condition
    when Hash then condition.any? { |key, value| key.to_s == column || names?(value, column) }
    when Array then condition.any? { |each| names?(each, column) }
    else false
    end
  end

  # The conditions as one Searchkick `where:`, all of which hold: the app's
  # (@builder), the @eq ones, @trashed's. Their keys are read alike, symbols or
  # strings; conditions on different keys merge, and ones on a key more than one
  # names are ANDed (Searchkick's `_and`), never overwritten.
  def all_of(*conditions)
    conditions = conditions.compact.map { |condition| condition.to_h.transform_keys(&:to_sym) }.reject(&:empty?)
    keys = conditions.flat_map(&:keys)
    keys.uniq.size == keys.size ? conditions.reduce({}, :merge) : { _and: conditions }
  end

  # @trashed's condition; without one, the records that are not trashed when the
  # model's default scope hides the others (paranoia's), as they would not load.
  # That one needs the index to hold the column only when it can be told: on an
  # index without it, `WITHOUT` matches every hit, and the load still leaves the
  # trashed records out.
  def trashed_filter(query)
    trashed = query.trashed || (:without if hides_trashed?(query.model))
    return {} if trashed.nil? || trashed == :with # no filter: the index need not hold the column

    column, kept = trashed_column(query.model)
    require_indexed!(query, column, told: query.trashed.nil?)
    trashed == :only ? { column.to_sym => { not: kept } } : { column.to_sym => kept }
  end

  # Does the model's default scope leave its trashed records out?
  def hides_trashed?(model)
    Lighthouse::Support::SoftDeletes.supported?(model) &&
      !Lighthouse::Support::Relations.same_records?(model.all, Lighthouse::Support::SoftDeletes.with_trashed(model.all))
  end

  # [the indexed column that marks trashed records, its value for the others]:
  # the soft-delete adapter's (paranoia's, with its sentinel; discard's;
  # Config.soft_deletes'), which the database filters and the records load
  # through too; deleted_at when an app's adapter does not tell.
  def trashed_column(model)
    [Lighthouse::Support::SoftDeletes.column(model) || DEFAULT_TRASHED_COLUMN, Lighthouse::Support::SoftDeletes.kept_value(model)]
  end

  # The index must hold the column, or the filter would match nothing (or everything).
  # The model's search_data tells for its own index, the engine's mapping for any
  # other `within:` names (or when search_data cannot run on a blank record). It
  # fails closed: when the columns cannot be told, the search is refused too,
  # naming why the mapping could not be read; unless `told` (Lighthouse's own
  # filter, which holds either way) lets it go on.
  def require_indexed!(query, column, told: false)
    model = query.model
    indexed = (indexed_columns(model) if own_index?(query)) || @index.fields(model, index_name(query))
    return if indexed.nil? && told

    unless indexed
      raise ::GraphQL::ExecutionError,
            "@trashed cannot tell whether #{index_label(query)} holds #{column}, which it filters the search on: " \
            "#{model.name}#search_data does not run on a blank record, and the index's mapping cannot be read#{mapping_failure(query)}."
    end
    return if indexed.include?(column.to_s)

    raise ::GraphQL::ExecutionError, "#{index_label(query)} does not hold #{column}, which @trashed filters the search on: add it to search_data."
  end

  def index_label(query) = own_index?(query) ? "#{query.model.name}'s index" : "the index #{query.index}"

  # Why the engine did not answer the index's mapping, and the privilege reading it needs.
  def mapping_failure(query)
    error = @index.failure(:mapping, query.model, index_name(query))
    " (#{error.class}: #{error.message}; reading it needs the view_index_metadata privilege on the index)" if error
  end

  # What `search_data` holds, or nil when it cannot run on a blank record, read
  # once per model class.
  def indexed_columns(model)
    @per_model.get([:indexed_columns, model.name], model) do
      model.new.search_data.keys.map(&:to_s)
    rescue StandardError
      nil
    end
  end
end
