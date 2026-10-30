# frozen_string_literal: true

# What an @builder may ask of Searchkick's search (`query.options`), and which
# of the engine's conditions the database applies alike (Search::Searchkick).
module Lighthouse::Search::Searchkick::Options
  module_function

  # The options of Searchkick's `search` an @builder on an argument may set
  # (`query.options`): what ranks, highlights or aggregates the hits, never what
  # loads them, pages them or counts them (`load:`, `index_name:`, `models:`,
  # `unscope:`, `page:`, `body:`, ...), which Lighthouse sets. `where:` and
  # `scope_results:` compose with Lighthouse's own.
  BUILDER_OPTIONS = %i[
    fields match operator where order boost_by boost_where boost_by_distance boost_by_recency indices_boost
    misspellings highlight aggs smart_aggs emoji exclude conversions conversions_term explain debug
    includes model_includes scope_results body_options timeout
  ].freeze

  # The keys of `body_options:` an @builder may set: none that replaces the query,
  # its paging or its count (`query`, `size`, `from`, `track_total_hits`, `terminate_after`, ...).
  BODY_OPTIONS = %i[min_score explain profile timeout].freeze

  # The values the database compares a column with as the engine does: a
  # scalar, a list of them, a Range of them (BETWEEN). Not an engine operator
  # (`{ gt: 3 }`) nor a Regexp, which are the index's alone.
  SQL_SCALARS = [String, Symbol, Numeric, TrueClass, FalseClass, NilClass, Date, Time].freeze

  # The options an @builder set (query.options), which must be BUILDER_OPTIONS,
  # their keys read alike, symbols or strings.
  def builder!(query)
    options = query.options.to_h.transform_keys(&:to_sym)
    refused = options.keys - BUILDER_OPTIONS
    return options if refused.empty?

    raise Lighthouse::DefinitionError,
          "@search: an @builder may not set #{refused.map { |key| "`#{key}:`" }.join(', ')} of Searchkick's search, which decide " \
          "what loads, how it pages or what it counts, and which Lighthouse sets; it may set #{BUILDER_OPTIONS.join(', ')}"
  end

  # The app's body_options (BODY_OPTIONS), and track_total_hits: true, which they may not set.
  def counting(options)
    body = (options[:body_options] || {}).to_h.transform_keys(&:to_sym)
    if body.key?(:track_total_hits)
      raise Lighthouse::DefinitionError,
            '@search: Lighthouse asks the engine to count every match (track_total_hits: true), which totals, pages and ' \
            "@canQuery's check of every hit rely on: body_options cannot set track_total_hits"
    end
    refused = body.keys - BODY_OPTIONS
    unless refused.empty?
      raise Lighthouse::DefinitionError,
            "@search: body_options may not set #{refused.join(', ')}, which would replace the search's query, paging or count; " \
            "it may set #{BODY_OPTIONS.join(', ')}"
    end
    body.merge(track_total_hits: true)
  end

  # The engine conditions the database applies alike: a column of the model, and a
  # value the database compares as the engine does (SQL_SCALARS: a scalar, a list
  # or a Range of them).
  def database_wheres(query)
    columns = query.model.column_names
    query.wheres.select { |column, value| columns.include?(column) && sql_value?(value) }
  end

  def sql_value?(value)
    case value
    when Array then value.all? { |each| scalar?(each) }
    when Range then scalar?(value.begin) && scalar?(value.end)
    else scalar?(value)
    end
  end

  def scalar?(value) = SQL_SCALARS.any? { |kind| value.is_a?(kind) }
end
