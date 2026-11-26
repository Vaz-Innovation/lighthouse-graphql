# frozen_string_literal: true

# The subgraph's SDL, which `Query._service { sdl }` answers and the gateway
# composes, as PHP Lighthouse's FederationPrinter prints it: the schema as
# clients see it (Lighthouse's directives are not in it, see ServerDirectives),
# with its `extend schema @link(...)` and every directive it applies, on every
# kind of member, but without what the spec adds or declares: `_Any`,
# `_Entity`, `_Service`, `Query._entities` and `_service` (and Query itself,
# when it has no other field), and the definitions of the spec's directives and
# types, which the gateway knows from the link. Directives the app declares
# (one it composes with @composeDirective) keep their definitions.
module Lighthouse::GraphQL::Federation::Printer
  Nodes = ::GraphQL::Language::Nodes

  module_function

  def print(schema)
    "#{::GraphQL::Language::Printer.new.print(document(schema)).strip}\n"
  end

  def document(schema)
    link = Lighthouse::GraphQL::Federation.schema_link(schema)
    document = ::GraphQL::Language::DocumentFromSchemaDefinition.new(schema).document
    spec_directives = Lighthouse::GraphQL::Federation::Definitions.directives(link).keys.to_set
    spec_types = Lighthouse::GraphQL::Federation::Definitions.types(link).keys.to_set + Lighthouse::GraphQL::Federation::TYPES

    definitions = document.definitions.filter_map do |definition|
      case definition
      when Nodes::DirectiveDefinition then definition unless spec_directives.include?(definition.name)
      when Nodes::SchemaDefinition, Nodes::SchemaExtension then definition
      else root_query(schema, definition) unless spec_types.include?(definition.name)
      end
    end
    document.merge(definitions: definitions)
  end

  # Query without the spec's fields; nil when nothing else is left.
  def root_query(schema, definition)
    return definition unless definition.is_a?(Nodes::ObjectTypeDefinition) && definition.name == schema.query&.graphql_name

    fields = definition.fields.reject { |field| Lighthouse::GraphQL::Federation::FIELDS.include?(field.name) }
    definition.merge(fields: fields) if fields.any?
  end
end
