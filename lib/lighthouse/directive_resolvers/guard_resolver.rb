# frozen_string_literal: true

require_relative 'base'

# @guard — require an authenticated user before the field resolves.
# Wraps the field's resolver; raises "Unauthenticated." (AuthenticationError,
# extensions.code UNAUTHENTICATED) when no user is present (per
# Config.authenticated_user). Mirrors PHP Lighthouse's @guard.
class Lighthouse::GraphQL::DirectiveResolvers::GuardDirectiveResolver < Lighthouse::GraphQL::DirectiveResolvers::BaseDirectiveResolver
  def self.directive_name = 'guard'

  def self.definition
    <<~GRAPHQL.chomp
      """
      Require an authenticated user (see Config.authenticated_user) before the field resolves,
      else fail with "Unauthenticated.".
      """
      directive @guard on FIELD_DEFINITION
    GRAPHQL
  end

  def define_resolver(target_type_class)
    field_name = @field_def.name
    method_name = "resolve_field_#{field_name}"
    inner = Lighthouse::GraphQL::DirectiveResolvers::Resolution.capture(target_type_class, method_name, @field_def, field_name)

    wrapper = lambda do |obj, arguments, ctx|
      raise Lighthouse::AuthenticationError unless Lighthouse::Support::Authorization.authenticated?(ctx)

      inner.call(obj, arguments, ctx)
    end

    target_type_class.define_singleton_method(method_name, &wrapper)
    @field_def.resolve_proc = wrapper if @field_def.respond_to?(:resolve_proc=)
  end
end
