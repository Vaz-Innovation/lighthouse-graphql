# frozen_string_literal: true

# The code-first types graphql-ruby's install writes, which a schema builds on:
#
#   base_types: { query_type: Types::QueryType, mutation_type: Types::MutationType,
#                 subscription_type: Types::SubscriptionType, node: Types::NodeType }
#
# - A root type given is what the SDL's root type of that kind is built on,
#   instead of base_types[:object]: the SDL's `type Query` is a subclass of
#   Types::QueryType, so the `field`s the class declares (graphql-ruby's
#   `node` / `nodes`, what `graphql:mutation` adds to Types::MutationType)
#   are the schema's too, beside the SDL's, and resolve as in graphql-ruby. An
#   SDL field of the same name wins. With no such root type in the SDL, the
#   class itself is the root, once it declares a field.
# - `node:` is the SDL's Node interface: `interface Node`, which @node adds and
#   `implements Node` names, is that module, so graphql-ruby's Relay
#   (Query.node / nodes, the schema's id_from_object / object_from_id) and the
#   SDL's @node types share one Node. The `node` field @node adds to Query then
#   gives way to the root type class's own.
#
# graphql-ruby's builder knows one base per kind, so the hook into it is a
# patch (graphql_ruby_patches.rb), which reads the bases of the build in
# progress from here.
module Lighthouse::GraphQL::RootTypes
  KEYS = %i[query_type mutation_type subscription_type node].freeze

  ROOTS = { query_type: :query, mutation_type: :mutation, subscription_type: :subscription }.freeze

  # The resolver of the `node` field @node adds to Query.
  NODE_RESOLVER = 'Lighthouse::GraphQL::NodeRegistry@resolve'

  module_function

  def validate!(key, type)
    valid = key == :node ? Lighthouse::GraphQL::Type.kind_of(type) == :interface : type.is_a?(Class) && type < ::GraphQL::Schema::Object
    return if valid

    expected = key == :node ? 'a module including GraphQL::Schema::Interface' : 'a subclass of GraphQL::Schema::Object'
    raise Lighthouse::DefinitionError, "base_types[:#{key}] must be #{expected}, not #{type.inspect}."
  end

  # The root type class the SDL's root type of `root_kind` (:queries,
  # :mutations) is built on, when it is Lighthouse's (Lighthouse::GraphQL::Type):
  # its methods resolve the root fields of their name.
  def type_class(root_kind, roots)
    klass = roots&.[]({ queries: :query_type, mutations: :mutation_type }[root_kind])
    klass if klass&.include?(Lighthouse::GraphQL::Type)
  end

  # Run the block (the build of `document`) with `roots` as the bases of the
  # types they name.
  def with(document, roots)
    previous = Thread.current[:lighthouse_root_types]
    Thread.current[:lighthouse_root_types] = by_type_name(document, roots || {})
    yield
  ensure
    Thread.current[:lighthouse_root_types] = previous
  end

  # The class an SDL type of `name` is built on, or nil.
  def base_for(name)
    Thread.current[:lighthouse_root_types]&.[](name)
  end

  # `definition` without the fields `base` declares itself that @node added.
  def definition_on(definition, base)
    names = field_names(base)
    fields = definition.fields.reject { |field| names.include?(field.name) && added_by_node?(field) }
    fields.size == definition.fields.size ? definition : definition.merge(fields: fields)
  end

  # The names of the fields a class and its ancestors declare. Not `fields`,
  # which warns about a type with none (graphql-ruby's install leaves
  # Types::MutationType empty once its example field goes).
  def field_names(type)
    type.ancestors.select { |ancestor| ancestor.respond_to?(:own_fields) }.flat_map { |ancestor| ancestor.own_fields.keys }.uniq
  end

  # The schema the block builds from `document`, with `roots` as the bases of
  # the types they name; then the root type classes the SDL has no type for,
  # and the subscriptions backend an app schema class `use`s (graphql_ruby_patches.rb).
  def build(document, roots, &block)
    schema = with(document, roots, &block)
    apply_missing(schema, roots)
    schema.extend(Lighthouse::GraphQL::InheritedSubscriptionRoot) if schema.respond_to?(:add_subscription_extension_if_necessary, true)
    schema
  end

  # A root type class the SDL has no type for is the root itself, once it
  # declares a field (graphql-ruby's install writes them with an example one).
  def apply_missing(schema, roots)
    ROOTS.each do |key, root|
      type = roots&.[](key)
      next if type.nil? || schema.public_send(root) || field_names(type).empty?

      schema.public_send(root, type)
    end
  end

  def by_type_name(document, roots)
    names = root_names(document)
    mapped = ROOTS.each_with_object({}) { |(key, root), out| out[names[root]] = roots[key] if roots[key] }
    roots[:node] ? mapped.merge('Node' => roots[:node]) : mapped
  end

  # { query: 'Query', ... }, as the document's `schema { }` names them.
  def root_names(document)
    schema = document.definitions.find { |definition| definition.is_a?(::GraphQL::Language::Nodes::SchemaDefinition) }
    { query: schema&.query || 'Query', mutation: schema&.mutation || 'Mutation', subscription: schema&.subscription || 'Subscription' }
  end

  def added_by_node?(field)
    field.directives.any? do |directive|
      directive.name == 'field' && Lighthouse::Support::DirectiveArgs.literal(directive, 'resolver') == NODE_RESOLVER
    end
  end
end
