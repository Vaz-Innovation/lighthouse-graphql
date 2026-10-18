# frozen_string_literal: true

# How the values of an SDL scalar (`scalar DateTime`) are read from a query and
# written to a response, as a graphql-ruby scalar class does it with
# `coerce_input(value, context)` and `coerce_result(value, context)`. The class
# is, in order:
#
# 1. the one `@scalar(class: "Name")` on the scalar names, looked up in
#    Config.namespaces[:types] (nested names too) and then as written. PHP
#    Lighthouse's directive.
# 2. Its type class, Types::<Name>Type including Lighthouse::GraphQL::Type: a
#    GraphQL::Schema::Scalar, as graphql-ruby's `rails g graphql:scalar` writes it.
# 3. Lighthouse's own, for `scalar Upload` (Lighthouse::GraphQL::Upload).
#
# A scalar with none passes its values through unchanged. A class raising
# GraphQL::CoercionError from coerce_input (or returning nil for a value) makes
# the argument invalid, with that message, as in graphql-ruby.
module Lighthouse::GraphQL::ScalarCoercion
  DEFINITION = <<~GRAPHQL.chomp
    """
    The class that reads and writes this scalar's values: coerce_input(value, context) and
    coerce_result(value, context), as a GraphQL::Schema::Scalar.
    """
    directive @scalar(class: String!) on SCALAR
  GRAPHQL

  module_function

  # Give every SDL scalar that has a class its coercion. The class is looked up
  # again on each value, so code reloading keeps working; `bases` is the
  # schema's base_types[:scalar], which a type class must inherit from.
  def apply(schema, base = nil)
    schema.types.each_value do |type|
      next unless type.kind.scalar? && type.ast_node

      klass = class_for(type, base)
      install(type, klass) if klass
    end
  end

  # Scalars Lighthouse brings a class for, when nothing else names one.
  BUILT_IN = { 'Upload' => 'Lighthouse::GraphQL::Upload' }.freeze

  def class_for(scalar_type, base = nil)
    directive_class(scalar_type) || type_class(scalar_type, base) || BUILT_IN[scalar_type.graphql_name]&.constantize
  end

  def directive_class(scalar_type)
    directive = (scalar_type.ast_node.directives || []).find { |d| d.name == 'scalar' }
    name = directive && Lighthouse::Support::DirectiveArgs.literal(directive, 'class')
    return unless name

    klass = Lighthouse::Support::ModelResolver.constantize(name, namespaces: Lighthouse::Config.namespaces[:types], nested: true)
    return klass if klass.respond_to?(:coerce_input) && klass.respond_to?(:coerce_result)

    raise Lighthouse::DefinitionError,
          "@scalar(class: #{name.inspect}) on #{scalar_type.graphql_name} names no class with coerce_input(value, context) " \
          'and coerce_result(value, context).'
  end

  def type_class(scalar_type, base)
    klass = Lighthouse::GraphQL::Type.class_for(scalar_type.graphql_name, :scalar)
    Lighthouse::GraphQL::ResolverBases.check!(klass, base, "the #{scalar_type.graphql_name} scalar") if klass
    klass
  end

  def install(scalar_type, klass)
    current = -> { klass.name ? klass.name.constantize : klass }
    scalar_type.define_singleton_method(:coerce_input) { |value, ctx| current.call.coerce_input(value, ctx) }
    scalar_type.define_singleton_method(:coerce_result) { |value, ctx| current.call.coerce_result(value, ctx) }
  end
end
