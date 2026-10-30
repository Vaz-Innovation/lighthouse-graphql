# frozen_string_literal: true

# Full-text search behind one seam, for @search. Laravel Scout is the abstraction
# PHP Lighthouse has; Ruby has two gems, so an adapter stands between the
# directives and the engine. It answers:
#
#   searchable?(model, index = nil)   can this model be searched (within the scope or index `index` names)?
#   relational?                       is the search a scope on the model's relation (pg_search)?
#   scope(relation, query)            relational: the relation narrowed to the matches, ranked
#   page(query, offset:, limit:)      otherwise: [records, total] of the engine's response
#
# `query` is a Search::Query. A relational adapter lets every other directive of
# the field apply on top of the scope; the others (Searchkick) answer on their own
# and take only the directives that include Contracts::SearchBuilder. The
# protocol is experimental until both adapters have shipped.
#
# The adapter is detected per model (Search::Auto): Searchkick, then pg_search.
# `Config.search` replaces the detection with one adapter, or the app's own.
#
# A model's `search_results` scope, when it has one, is what a search of it may
# return, checked in the database: pg_search applies it to the search, Searchkick
# loads the records it finds through it (`scope_results:`), so a record an index
# not yet updated still holds is not returned.
module Lighthouse::Search
  RESULTS_SCOPE = :search_results

  module_function

  # The adapter in use: Config.search, else the detecting one.
  def adapter
    Lighthouse::Config.search || (@default ||= Lighthouse::Search::Auto.new)
  end

  # The adapter that searches `model`, or nil.
  def adapter_for(model, index = nil)
    adapter = self.adapter
    return adapter.adapter_for(model, index) if adapter.respond_to?(:adapter_for)

    adapter if adapter.searchable?(model, index)
  end

  # Does the model have a `search_results` scope?
  def results_scope?(model) = model.respond_to?(RESULTS_SCOPE)

  # The relation through the model's `search_results` scope, if it has one.
  def results(relation)
    results_scope?(relation.klass) ? relation.public_send(RESULTS_SCOPE) : relation
  end

  # [path, @search directive node] for every argument and input field of the
  # field carrying @search, at any depth; an input type is not walked twice on one path.
  def directives(field_def)
    in_arguments(field_def.arguments, nil, Set.new)
  end

  # Does the field have an argument or input field with @search? Walked once per
  # field, the first time it is asked (Search::FieldCheck, when the schema is
  # built), and kept on the field: a schema built again on reload starts afresh.
  def searching?(field_def)
    return field_def.instance_variable_get(:@lighthouse_searching) if field_def.instance_variable_defined?(:@lighthouse_searching)

    field_def.instance_variable_set(:@lighthouse_searching, directives(field_def).any?)
  end

  def in_arguments(arguments, prefix, seen)
    arguments.each_value.flat_map do |argument|
      path = [prefix, argument.graphql_name].compact.join('.')
      own = (argument.ast_node&.directives || []).select { |d| d.name == 'search' }.map { |dnode| [path, dnode] }
      own + in_input_fields(argument.type.unwrap, path, seen)
    end
  end
  private_class_method :in_arguments

  def in_input_fields(type, path, seen)
    return [] unless type.kind.input_object? && seen.exclude?(type.graphql_name)

    in_arguments(type.arguments, path, seen | [type.graphql_name])
  end
  private_class_method :in_input_fields
end
