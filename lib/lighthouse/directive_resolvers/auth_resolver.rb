# frozen_string_literal: true

class Lighthouse::GraphQL::DirectiveResolvers::AuthDirectiveResolver < Lighthouse::GraphQL::DirectiveResolvers::BaseDirectiveResolver
  def self.directive_name = 'auth'

  def self.definition
    <<~GRAPHQL.chomp
      """
      Require an authenticated user (`context[:current_user]`) before the field resolves,
      else fail with "Unauthenticated.". @guard is the configurable equivalent.
      """
      directive @auth on FIELD_DEFINITION
    GRAPHQL
  end

  def define_resolver(target_type_class)
    inner = original_resolver(target_type_class)

    install(target_type_class, lambda do |obj, arguments, ctx|
      user = ctx && (ctx[:current_user] || ctx['current_user'])
      raise Lighthouse::AuthenticationError unless user

      inner.call(obj, arguments, ctx)
    end)
  end

  private

  # The field's resolver so far: an existing `resolve_field_*` method, the
  # resolve_proc, or the parent's attribute reader.
  def original_resolver(target_type_class)
    field_name = @field_def.name
    original_singleton =
      (target_type_class.method(resolver_method_name) if target_type_class.respond_to?(resolver_method_name))

    original_proc =
      (@field_def.resolve_proc if @field_def.respond_to?(:resolve_proc))

    lambda do |obj, arguments, ctx|
      if original_singleton
        original_singleton.call(obj, arguments, ctx)
      elsif original_proc
        original_proc.call(obj, arguments, ctx)
      else
        read_attribute(obj, field_name)
      end
    end
  end

  def read_attribute(obj, field_name)
    return obj.public_send(field_name) if obj.respond_to?(field_name)

    snake = field_name.to_s.underscore
    obj.respond_to?(snake) ? obj.public_send(snake) : nil
  end
end
