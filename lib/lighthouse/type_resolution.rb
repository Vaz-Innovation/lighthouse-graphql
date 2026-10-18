# frozen_string_literal: true

# Which object type a value of a union or interface is: graphql-ruby asks the
# schema (its `resolve_type`) each time a field returns one. In order:
#
# 1. `@union(resolveType: "Name")` / `@interface(resolveType: "Name")` on the
#    SDL type names a class, looked up in Config.namespaces[:types] (nested
#    names too) and then as written, with `resolve_type(object, context)` or
#    `call(object, context)`. PHP Lighthouse's directives.
# 2. Its type class, Types::<Name>Type including Lighthouse::GraphQL::Type: a
#    union's `self.resolve_type(object, context)`, or an interface's
#    `definition_methods { def resolve_type(object, context) }`, as in graphql-ruby.
# 3. The default, as PHP Lighthouse's: a Hash's `__typename`; else the type
#    named after the object's class, or one of its superclasses (STI); else the
#    type whose @model names the object's model (`type Article @model(class: "Post")`).
#
# A class returns a type name, the SDL type, or a type class (Types::PostType),
# which stands for the SDL type of its graphql_name; or, as graphql-ruby allows,
# [type, value] to resolve the type's fields on `value`. nil falls through to the
# next step. A value no step resolves, or one resolved to a type the union or
# interface does not include, raises Lighthouse::DefinitionError.
module Lighthouse::GraphQL::TypeResolution
  DEFINITIONS = {
    'union' => <<~GRAPHQL.chomp,
      """
      The class that picks the object type of this union's values: `resolve_type(object, context)`
      or `call(object, context)`, returning a type name or a type class.
      """
      directive @union(resolveType: String!) on UNION
    GRAPHQL
    'interface' => <<~GRAPHQL.chomp
      """
      The class that picks the object type of this interface's values: `resolve_type(object, context)`
      or `call(object, context)`, returning a type name or a type class.
      """
      directive @interface(resolveType: String!) on INTERFACE
    GRAPHQL
  }.freeze

  DIRECTIVES = DEFINITIONS.keys.freeze

  module_function

  # The object type, or [object type, value] when a class answered with a
  # value to resolve the fields on instead of `object` (as graphql-ruby allows).
  def resolve(schema, abstract_type, object, context)
    answer = custom(abstract_type, object, context)
    answer, value = answer if answer.is_a?(Array) && answer.size == 2
    type = type_named(schema, answer) || default(schema, abstract_type, object)
    unless type && schema.possible_types(abstract_type).include?(type)
      raise Lighthouse::DefinitionError, unresolved_message(schema, abstract_type, object, type)
    end

    value.nil? ? type : [type, value]
  end

  # What the directive's class or the type class says, or nil.
  def custom(abstract_type, object, context)
    resolver = directive_class(abstract_type) || type_class(abstract_type)
    return unless resolver

    resolver.respond_to?(:resolve_type) ? resolver.resolve_type(object, context) : resolver.call(object, context)
  end

  def default(schema, abstract_type, object)
    candidates = schema.possible_types(abstract_type)
    by_name = candidates.index_by(&:graphql_name)

    typename = typename_of(object)
    return by_name[typename] if typename

    class_chain(object.class).each { |name| return by_name[name] if by_name.key?(name) }
    candidates.find { |type| model_of(type)&.then { |model| object.is_a?(model) } }
  end

  # Fail at build time, not on the first query: every class a @union /
  # @interface names exists and answers, and every type class matches its kind.
  # `bases`: the schema's base_types, by kind, that type classes inherit from.
  def validate!(schema, bases = {})
    schema.types.each_value do |type|
      next unless type.kind.union? || type.kind.interface?

      directive_class(type)
      kind = type.kind.union? ? :union : :interface
      klass = Lighthouse::GraphQL::Type.class_for(type.graphql_name, kind)
      Lighthouse::GraphQL::ResolverBases.check!(klass, bases[kind], "the #{type.graphql_name} #{kind}") if klass
    end
  end

  # The SDL type a resolver's answer stands for: a name, a type, or a type class.
  def type_named(schema, answer)
    return if answer.nil?

    schema.get_type(answer.respond_to?(:graphql_name) ? answer.graphql_name : answer.to_s)
  end

  def directive_class(abstract_type)
    directive, name = resolve_type_directive(abstract_type)
    return unless name

    klass = Lighthouse::Support::ModelResolver.constantize(name, namespaces: Lighthouse::Config.namespaces[:types], nested: true)
    return klass if klass.respond_to?(:resolve_type) || klass.respond_to?(:call)

    raise Lighthouse::DefinitionError,
          "@#{directive.name}(resolveType: #{name.inspect}) on #{abstract_type.graphql_name} names no class with resolve_type(object, context) " \
          'or call(object, context).'
  end

  # The @union / @interface on the type and the class name it gives, or nil.
  def resolve_type_directive(abstract_type)
    directive = (abstract_type.ast_node&.directives || []).find { |d| DIRECTIVES.include?(d.name) }
    [directive, Lighthouse::Support::DirectiveArgs.literal(directive, 'resolveType')] if directive
  end

  def type_class(abstract_type)
    kind = abstract_type.kind.union? ? :union : :interface
    klass = Lighthouse::GraphQL::Type.class_for(abstract_type.graphql_name, kind)
    klass if klass.respond_to?(:resolve_type)
  end

  def typename_of(object)
    return unless object.is_a?(Hash)

    (object['__typename'] || object[:__typename])&.to_s
  end

  # Admin, User, ApplicationRecord, ... for an Admin < User record.
  def class_chain(klass)
    names = []
    while klass
      names << klass.name.demodulize if klass.name
      klass = klass.superclass
    end
    names
  end

  def model_of(type)
    Lighthouse::GraphQL::Directives::ModelDirective.declared_model(type)
  end

  def unresolved_message(schema, abstract_type, object, type)
    possible = schema.possible_types(abstract_type).map(&:graphql_name).join(' | ')
    kind = abstract_type.kind.union? ? 'union' : 'interface'
    return "#{abstract_type.graphql_name} resolved a #{object.class} to #{type.graphql_name}, which is not one of its types (#{possible})." if type

    "Lighthouse could not tell the type of a #{object.class} in the #{kind} #{abstract_type.graphql_name} (#{possible}): " \
      "name a type after its class, map one to it with @model(class: \"#{object.class}\"), or resolve it in " \
      "Types::#{abstract_type.graphql_name}Type.resolve_type or with @#{kind}(resolveType:)."
  end
end
