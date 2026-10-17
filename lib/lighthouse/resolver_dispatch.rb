# frozen_string_literal: true

# Calls the class a field resolves to. Classes in the queries and mutations
# namespaces follow graphql-ruby's contract — GraphQL::Schema::Resolver and
# GraphQL::Schema::Mutation: `resolve(**args)` with `object` and `context`,
# plus `ready?` / `authorized?` — exactly as in a graphql-ruby schema.
# @field also accepts a plain callable, `call(object, args, context)`.
module Lighthouse::GraphQL::ResolverDispatch
  module_function

  def graphql_resolver?(klass)
    klass.is_a?(Class) && klass < ::GraphQL::Schema::Resolver
  end

  def call(klass, field_def, obj, args, ctx)
    if graphql_resolver?(klass)
      kwargs = Lighthouse::Support::Arguments.prepare(field_def, args, ctx)
      klass.new(object: obj, context: ctx, field: field_def).resolve_with_support(**kwargs)
    elsif klass.respond_to?(:call)
      klass.call(obj, args, ctx)
    else
      instance = klass.new
      instance.respond_to?(:call) ? instance.call(obj, args, ctx) : instance.resolve(obj, args, ctx)
    end
  end
end
