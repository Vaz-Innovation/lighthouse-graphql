# frozen_string_literal: true

# How the `resolve_field_<name>` singletons that directive resolvers define on
# a schema's types are found and called at runtime. graphql-ruby resolves an
# SDL-built schema through `definition_default_resolve` and `resolve_<field>`
# methods of its own; the hooks here route both to ours.
module Lighthouse::GraphQL::GeneratedResolvers
  module_function

  def method_name(field_name)
    "resolve_field_#{field_name}"
  end

  def field_name(field)
    field.respond_to?(:graphql_name) ? field.graphql_name.to_s : field.name.to_s
  end

  # GraphQL-Ruby's SDL builder also defines `resolve_field_*` methods
  # internally. Only ours are defined under `lib/lighthouse/`; calling one of
  # graphql-ruby's would use the wrong arity.
  def generated?(resolver)
    source_file, = resolver.source_location
    source_file&.include?('/lib/lighthouse/')
  end

  # Generated resolvers take either (obj, args) or (obj, args, ctx).
  def invoke(resolver, obj, args, ctx)
    return resolver.call(obj, args) if resolver.parameters.length == 2

    resolver.call(obj, args, ctx)
  end

  # GraphQL-Ruby caches field resolution procs during schema build; rather
  # than trying to override per-field `resolve_<field>` methods post-hoc,
  # we install a single dispatcher here that prefers our generated
  # `resolve_field_<name>` singletons.
  def install_dispatcher(schema)
    return unless schema.respond_to?(:definition_default_resolve=) && schema.respond_to?(:definition_default_resolve)

    previous_default = schema.definition_default_resolve
    schema.definition_default_resolve = proc do |type, field, obj, arguments, ctx|
      resolver = generated_resolver(schema, type, field)
      next invoke(resolver, obj, arguments, ctx) if resolver

      previous_default.call(type, field, obj, arguments, ctx)
    end
  end

  # Our generated resolver for `field`, looked up on the schema's own type
  # (nil when there is none).
  def generated_resolver(schema, type, field)
    owner = schema_type(schema, type)
    name = method_name(field_name(field))
    return unless owner.respond_to?(name)

    resolver = owner.method(name)
    resolver if generated?(resolver)
  end

  def schema_type(schema, type)
    if type.respond_to?(:graphql_name)
      schema.types[type.graphql_name]
    elsif type.respond_to?(:name)
      schema.types[type.name.to_s]
    end
  end

  # GraphQL-Ruby's SDL builder defines `resolve_<field>` methods that call
  # the schema's `definition_default_resolve`. Override `resolve_<field>`
  # to delegate to our generated `resolve_field_<field>` when present, so
  # runtime resolution consistently reaches our directive resolvers.
  def route_runtime_resolver(type, field_def)
    generated = method_name(field_def.name)
    return unless type.respond_to?(generated)

    type.define_singleton_method("resolve_#{field_def.name}") do |obj, arguments, ctx|
      public_send(generated, obj, arguments, ctx)
    end
  rescue StandardError
    # ignore override failures
  end
end
