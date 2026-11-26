# frozen_string_literal: true

# An app coming from graphql-ruby's code-first federation follows the
# apollo-federation gem's setup: a mixin in each base class
# (ApolloFederation::Object, Interface, Union, Enum, EnumValue, Scalar,
# InputObject, Field, Argument) and ApolloFederation::Schema in the schema.
# Lighthouse is the subgraph itself, from the SDL: those mixins would not
# federate anything here. The type mixins' declarations (`key fields: :id`,
# `field :name, external: true`) are never read, and the schema mixin replaces
# the subgraph's SDL and `_entities` with the gem's, which link Federation 2.3
# whatever the SDL says. So each is refused, by name, with what to write instead
# (docs/federation.md#migrating-from-apollo-federation): the base types when the
# schema is built, the schema mixin as the app's schema class includes it.
# The gem need not be loaded; its tracing plugin (`use ApolloFederation::Tracing`) is no mixin.
module Lighthouse::GraphQL::Federation::ApolloFederationCheck
  # The gem's mixins, and what each declared that the SDL says now.
  TYPE_MIXINS = {
    'Object' => '`key fields:`, `extend_type`, `shareable`, `interface_object` → @key, @extends, @shareable, @interfaceObject on the SDL type',
    'Interface' => '`key fields:` → @key on the SDL interface',
    'Union' => '`tag`, `inaccessible` → @tag, @inaccessible on the SDL union',
    'Enum' => '`tag`, `inaccessible` → @tag, @inaccessible on the SDL enum',
    'EnumValue' => '`tags:`, `inaccessible:` → @tag, @inaccessible on the SDL enum value',
    'Scalar' => '`tag`, `inaccessible` → @tag, @inaccessible on the SDL scalar',
    'InputObject' => '`tag`, `inaccessible` → @tag, @inaccessible on the SDL input',
    'Field' => '`external:`, `requires:`, `provides:`, `shareable:`, `override:`, `tags:` → @external, @requires, ... on the SDL field',
    'Argument' => '`tags:`, `inaccessible:` → @tag, @inaccessible on the SDL argument'
  }.freeze

  GUIDE = 'Lighthouse makes the schema a subgraph from its SDL: `extend schema @link(url: "https://specs.apollo.dev/federation/v2.9", ' \
          'import: ["@key", ...])` and the directives on its types. See docs/federation.md#migrating-from-apollo-federation.'

  # Refuses `include ApolloFederation::Schema` in a schema class built on Lighthouse's.
  module SchemaGuard
    def include(*modules)
      Lighthouse::GraphQL::Federation::ApolloFederationCheck.refuse_schema_mixin!(self, modules)
      super
    end
  end

  module_function

  # The base types (and the field, argument and enum value classes they use)
  # must not include the gem's mixins.
  def check_types!(base_types)
    found = base_classes(base_types).flat_map do |klass|
      TYPE_MIXINS.filter_map { |name, moved| "#{klass} includes ApolloFederation::#{name} (#{moved})" if includes?(klass, name) }
    end.uniq
    return if found.empty?

    raise Lighthouse::DefinitionError, "#{found.join('; ')}. Remove the apollo-federation mixins: #{GUIDE}"
  end

  # Guards `schema`, and the app's schema classes inheriting from it.
  def guard!(schema)
    schema.singleton_class.prepend(SchemaGuard) unless schema.singleton_class.include?(SchemaGuard)
  end

  def refuse_schema_mixin!(schema, modules)
    mixin = mixin('Schema')
    return unless mixin && modules.include?(mixin)

    raise Lighthouse::DefinitionError,
          "#{schema.name || schema} includes ApolloFederation::Schema, whose subgraph SDL and _entities would replace " \
          "Lighthouse's (linking Federation 2.3 whatever the SDL says). Remove it, with `federation(version:)` and " \
          "`query(superclass.query)`: #{GUIDE}"
  end

  # Every class a base type names, with the classes of its fields, arguments and enum values.
  def base_classes(base_types)
    base_types.values.grep(Module).flat_map do |klass|
      field_class = klass.respond_to?(:field_class) ? klass.field_class : nil
      argument_classes = [klass, field_class].filter_map { |owner| owner.argument_class if owner.respond_to?(:argument_class) }
      enum_value_class = klass.respond_to?(:enum_value_class) ? klass.enum_value_class : nil
      [klass, field_class, *argument_classes, enum_value_class]
    end.compact.uniq
  end

  def includes?(klass, name)
    mod = mixin(name)
    !mod.nil? && klass.include?(mod)
  end

  # The gem's mixin of that name, when the gem is loaded.
  def mixin(name)
    return unless defined?(::ApolloFederation) && ::ApolloFederation.const_defined?(name, false)

    ::ApolloFederation.const_get(name, false)
  end
end
