# frozen_string_literal: true

require_relative 'base'
require_relative 'builder_applier'

class Lighthouse::GraphQL::DirectiveResolvers::AllDirectiveResolver < Lighthouse::GraphQL::DirectiveResolvers::BaseDirectiveResolver
  def self.directive_name = 'all'
  def self.applies_search? = true
  def self.takes_search_results?(*) = true

  def self.definition
    <<~GRAPHQL.chomp
      """
      Get a collection of models as the field result: all the model's records,
      narrowed by `scopes`, @builder and the field's argument filters (@eq, @where, ...).
      """
      directive @all(
      #{MODEL_ARGUMENT}
      #{SCOPES_ARGUMENT}
      ) on FIELD_DEFINITION
    GRAPHQL
  end

  def define_resolver(target_type_class)
    model_class = constantize_model(extract_model_name || @field_def.type.unwrap.graphql_name)
    me = self

    install(target_type_class, lambda do |_obj, arguments, ctx|
      me.send(:resolve_all, model_class, arguments, ctx)
    end)
  end

  private

  def resolve_all(model_class, arguments, ctx)
    return [] unless model_class

    # apply simple pagination args if present
    args = arguments.respond_to?(:to_h) ? arguments.to_h : {}
    relation = apply_scopes(model_class.all)

    relation = apply_where_filters(relation, args, ctx, search: :model)
    return search_records(relation, args, ctx) if relation.is_a?(Lighthouse::Search::Result)

    relation = relation.limit(args[:first]) if args[:first]
    relation = relation.offset(args[:offset]) if args[:offset]
    relation
  end

  # The records a search found: without `first`, Search::Result::READ_LIMIT of them
  # at most, and an error next to them when that leaves matches unread.
  def search_records(result, args, ctx)
    records = result.records(first: args[:first], offset: args[:offset])
    if result.truncated? && ctx.respond_to?(:add_error)
      ctx.add_error(::GraphQL::ExecutionError.new(
                      "@all reads #{Lighthouse::Search::Result::READ_LIMIT} matches at most without `first`, and this search finds " \
                      "#{result.reachable}: give the field `first` and `offset`, or use @paginate, to read the others."
                    ))
    end
    records
  end

  def extract_model_name
    arg = @directive_node.arguments&.find { |a| a.name == 'model' }
    return nil unless arg

    arg.value.respond_to?(:value) ? arg.value.value : arg.value
  end
end
