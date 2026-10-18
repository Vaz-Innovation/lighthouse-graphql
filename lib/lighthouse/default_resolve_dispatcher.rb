# frozen_string_literal: true

# The schema's default resolve while Lighthouse runs it. graphql-ruby asks that
# one object for every field, for the type of a union's or interface's value
# (`resolve_type`) and for scalar coercion: the dispatcher answers fields with
# our generated resolvers, and hands everything else to the implementation it
# replaced (SchemaImplementation).
class Lighthouse::GraphQL::DefaultResolveDispatcher
  def initialize(schema, previous)
    @schema = schema
    @previous = previous
  end

  def call(type, field, obj, arguments, ctx)
    resolver = Lighthouse::GraphQL::GeneratedResolvers.generated_resolver(@schema, type, field)
    return Lighthouse::GraphQL::GeneratedResolvers.invoke(resolver, obj, arguments, ctx) if resolver

    @previous.call(type, field, obj, arguments, ctx)
  end

  def resolve_type(abstract_type, obj, ctx) = @previous.resolve_type(abstract_type, obj, ctx)

  def coerce_input(type, value, ctx) = @previous.coerce_input(type, value, ctx)

  def coerce_result(type, value, ctx) = @previous.coerce_result(type, value, ctx)
end
