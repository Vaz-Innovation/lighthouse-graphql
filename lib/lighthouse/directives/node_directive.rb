# frozen_string_literal: true

# @node — Relay's global object identification, as PHP Lighthouse's directive.
# On a type, it makes the schema:
#
#   "Any object implementing this type can be found by ID through `Query.node`."
#   interface Node @interface(resolveType: "Lighthouse::GraphQL::NodeRegistry") {
#     "Global identifier that can be used to resolve any Node implementation."
#     id: ID!
#   }
#
#   type User implements Node @node { id: ID! @globalId ... }
#
#   type Query {
#     node(id: ID! @globalId): Node @field(resolver: "Lighthouse::GraphQL::NodeRegistry@resolve")
#   }
#
# leaving alone what the SDL declares itself (a Node interface, a Query.node
# field, with its own description or middleware). The type keeps its own
# `id: ID! @globalId`, which encodes the ids `node` decodes. NodeRegistry finds
# the record: through the type's `model:` or model, or its `resolver:`.
class Lighthouse::GraphQL::Directives::NodeDirective
  DEFINITIONS = {
    'node' => <<~GRAPHQL.chomp
      """
      Register a type for Relay's global object identification.

      When used without any arguments, Lighthouse will attempt
      to resolve the type through a model with the same name.
      """
      directive @node(
        """
        Reference to a class (and method, after `@`) that receives the decoded `id`
        and the context, and returns the object.

        Mutually exclusive with `model`.
        """
        resolver: String

        """
        Specify the class name of the model to use.
        This is only needed when the default model detection does not work.

        Mutually exclusive with `resolver`.
        """
        model: String
      ) on OBJECT
    GRAPHQL
  }.freeze

  INTERFACE = <<~GRAPHQL.chomp
    "Any object implementing this type can be found by ID through `Query.node`."
    interface Node @interface(resolveType: "Lighthouse::GraphQL::NodeRegistry") {
      "Global identifier that can be used to resolve any Node implementation."
      id: ID!
    }
  GRAPHQL

  NODE_FIELD = <<~GRAPHQL.chomp
    type Query {
      "Fetches an object given its globally unique `ID`."
      node(id: ID! @globalId): Node @field(resolver: "Lighthouse::GraphQL::NodeRegistry@resolve")
    }
  GRAPHQL

  OBJECTS = [::GraphQL::Language::Nodes::ObjectTypeDefinition, ::GraphQL::Language::Nodes::ObjectTypeExtension].freeze

  DECLARATION = /directive\s+@node\b/
  USAGE = /@node\b/

  def self.manipulate(sdl)
    return sdl unless sdl.is_a?(String) && sdl.gsub(DECLARATION, '').match?(USAGE)

    new(::GraphQL::Language::Parser.parse(sdl)).manipulate(sdl)
  rescue ::GraphQL::ParseError
    sdl
  end

  def initialize(document)
    @document = document
  end

  def manipulate(sdl)
    return sdl unless @document.definitions.any? { |definition| node?(definition) }

    definitions = @document.definitions.map { |definition| node?(definition) ? implement_node(definition) : definition }
    definitions = with_node_field(definitions)
    printed = ::GraphQL::Language::Printer.new.print(@document.merge(definitions: definitions))
    printed = "#{printed}\n\n#{INTERFACE}" unless declared?('Node')
    # The added @globalId, @field and @interface need their definitions too.
    Lighthouse::GraphQL::SchemaGenerator.inject_directive_definitions(printed)
  end

  private

  def node?(definition)
    OBJECTS.any? { |kind| definition.is_a?(kind) } && definition.directives.any? { |directive| directive.name == 'node' }
  end

  def implement_node(definition)
    return definition if definition.interfaces.any? { |interface| interface.name == 'Node' }

    definition.merge(interfaces: definition.interfaces + [::GraphQL::Language::Nodes::TypeName.new(name: 'Node')])
  end

  # Query gains `node`, unless a Query definition or extension has one. With
  # no Query at all, the schema gets one with `node` alone.
  def with_node_field(definitions)
    queries = definitions.select { |definition| query?(definition) }
    return definitions if queries.any? { |query| node_field?(query) }

    node_query = ::GraphQL::Language::Parser.parse(NODE_FIELD).definitions.first
    return definitions + [node_query] if queries.empty?

    definitions.map { |definition| definition.equal?(queries.first) ? definition.merge(fields: definition.fields + node_query.fields) : definition }
  end

  def node_field?(query)
    query.fields.any? { |field| field.name == 'node' }
  end

  def query?(definition)
    OBJECTS.any? { |kind| definition.is_a?(kind) } && definition.name == query_name
  end

  def query_name
    schema = @document.definitions.find { |definition| definition.is_a?(::GraphQL::Language::Nodes::SchemaDefinition) }
    schema&.query || 'Query'
  end

  def declared?(name)
    @document.definitions.any? { |definition| definition.respond_to?(:name) && definition.name == name && !definition.is_a?(::GraphQL::Language::Nodes::ObjectTypeExtension) }
  end
end
