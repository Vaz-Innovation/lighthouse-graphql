# frozen_string_literal: true

require_relative 'base'
require_relative 'builder_applier'

# @first(model: "Model") — return a single record (the first match). Like
# @all but `.first`, honoring `scopes:`, @builder and where/argument filters so it can
# be combined with @eq/@where to fetch one record by criteria.
class Lighthouse::GraphQL::DirectiveResolvers::FirstDirectiveResolver < Lighthouse::GraphQL::DirectiveResolvers::BaseDirectiveResolver
  def self.directive_name = 'first'
  def self.applies_search? = true

  def self.definition
    <<~GRAPHQL.chomp
      """
      Get the first record that matches the field's argument filters (@eq, @where, ...),
      or null. Unlike @find, it does not fail when more than one record matches.
      """
      directive @first(
      #{MODEL_ARGUMENT}
      #{SCOPES_ARGUMENT}
      ) on FIELD_DEFINITION
    GRAPHQL
  end

  def define_resolver(target_type_class)
    method_name = "resolve_field_#{@field_def.name}"
    model_name_static = directive_arg('model') || field_type_name
    resolver_instance = self

    resolver = lambda do |_obj, arguments, ctx|
      model_class = resolver_instance.constantize_model(model_name_static)
      next nil unless model_class

      args_h = arguments.respond_to?(:to_h) ? arguments.to_h : {}
      relation = resolver_instance.apply_scopes(model_class.all)
      relation = resolver_instance.apply_where_filters(relation, args_h, ctx)
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
