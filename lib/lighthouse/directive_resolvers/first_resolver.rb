# frozen_string_literal: true

require_relative 'base'
require_relative 'builder_applier'

# @first(model: "Model") — return a single record (the first match). Like
# @all but `.first`, honoring `scopes:`, @builder and where/argument filters so it can
# be combined with @eq/@where to fetch one record by criteria.
class Lighthouse::GraphQL::DirectiveResolvers::FirstDirectiveResolver < Lighthouse::GraphQL::DirectiveResolvers::BaseDirectiveResolver
  def self.directive_name = 'first'
  def self.definition = 'directive @first(model: String, scopes: [String!]) on FIELD_DEFINITION'

  def define_resolver(target_type_class)
    method_name = "resolve_field_#{@field_def.name}"
    model_name_static = directive_arg('model') || field_type_name
    resolver_instance = self
    field_ast_node = @field_def.ast_node

    resolver = lambda do |_obj, arguments, ctx|
      model_class = resolver_instance.constantize_model(model_name_static)
      next nil unless model_class

      args_h = arguments.respond_to?(:to_h) ? arguments.to_h : {}
      relation = resolver_instance.apply_scopes(model_class.all)
      relation = Lighthouse::GraphQL::DirectiveResolvers::BuilderApplier.apply(relation, field_ast_node, args_h, ctx, resolver_instance)
      relation = resolver_instance.apply_where_filters(relation, args_h)
      relation.first
    end

    target_type_class.define_singleton_method(method_name, &resolver)
    @field_def.resolve_proc = resolver if @field_def.respond_to?(:resolve_proc=)
  end

  private

  def directive_arg(name)
    Lighthouse::Support::DirectiveArgs.literal(@directive_node, name)
  end

  def field_type_name
    unwrapped = @field_def.type.respond_to?(:unwrap) ? @field_def.type.unwrap : @field_def.type
    return unwrapped.graphql_name if unwrapped.respond_to?(:graphql_name) && unwrapped.graphql_name
    return unwrapped.name if unwrapped.respond_to?(:name) && unwrapped.name

    @field_def.type.to_type_signature.to_s.gsub(/[!\[\]]/, '')
  end
end
