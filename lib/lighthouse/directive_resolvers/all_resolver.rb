# frozen_string_literal: true

require_relative 'base'
require_relative 'builder_applier'

class Lighthouse::GraphQL::DirectiveResolvers::AllDirectiveResolver < Lighthouse::GraphQL::DirectiveResolvers::BaseDirectiveResolver
  def self.directive_name = 'all'

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

    relation = apply_where_filters(relation, args, ctx)
    relation = relation.limit(args[:first]) if args[:first]
    relation = relation.offset(args[:offset]) if args[:offset]
    relation
  end

  def extract_model_name
    arg = @directive_node.arguments&.find { |a| a.name == 'model' }
    return nil unless arg

    arg.value.respond_to?(:value) ? arg.value.value : arg.value
  end
end
