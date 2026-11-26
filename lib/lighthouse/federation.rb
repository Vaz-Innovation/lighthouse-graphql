# frozen_string_literal: true

# Apollo Federation: the schema becomes a subgraph a gateway (Apollo Router)
# composes with others. Ported from PHP Lighthouse's Federation, on graphql-ruby:
#
#   extend schema @link(url: "https://specs.apollo.dev/federation/v2.9", import: ["@key", "@shareable"])
#
#   type User @key(fields: "id") { id: ID! name: String! }
#
# A schema linking the Federation 2 spec is a subgraph; `federation: true`
# makes one without the link a Federation 1 subgraph. Then, while the schema
# is built:
#
# - the spec's directives it uses are declared for it (Definitions), under the
#   names the link gives them;
# - the subgraph's types and fields are added, as the spec asks: `scalar _Any`,
#   `type _Service { sdl: String! }`, `Query._service`, and, when some object
#   type has @key, `union _Entity` of them and `Query._entities(representations:)`;
# - the types @paginate generates are @shareable (PaginationManipulator), since
#   every subgraph that paginates generates the same ones.
#
# `Query._service { sdl }` answers the subgraph's SDL (Printer), and
# `Query._entities` the entities the gateway asks for (Entities).
module Lighthouse::GraphQL::Federation
  Nodes = ::GraphQL::Language::Nodes

  # What `federation: true` prefixes to a schema without a link, so the build
  # (and its cache key) knows it is a Federation 1 subgraph.
  V1_MARKER = "# lighthouse: federation v1\n"

  ENTITIES_FIELD = '_entities'
  SERVICE_FIELD = '_service'
  FIELDS = [ENTITIES_FIELD, SERVICE_FIELD].freeze

  # The types the spec adds to a subgraph, which its SDL does not show.
  TYPES = %w[_Any _Entity _Service].freeze

  module_function

  # The SDL as `get_schema(options: { federation: })` asks for it: marked as a
  # Federation 1 subgraph when it has no link of its own.
  def prepare(sdl, federation)
    return sdl unless federation && Link.from_document(parse(sdl)).nil?

    "#{V1_MARKER}#{sdl}"
  rescue ::GraphQL::ParseError
    sdl
  end

  # The schema's Link, for a subgraph; nil for any other schema. `marked`: the
  # schema is a Federation 1 subgraph without a link of its own (V1_MARKER).
  def link_for(document, marked: false)
    Link.from_document(document) || (Link.v1 if marked)
  end

  # The manipulation phase's last step (SchemaGenerator.manipulate): the
  # subgraph's directives, types and root fields, on the manipulated SDL.
  # `marked`: the SDL as it came, which carries V1_MARKER for `federation: true`.
  def manipulate(sdl, marked = sdl)
    document_ast = Lighthouse::GraphQL::DocumentAST.from_source(sdl)
    link = link_for(document_ast.to_document, marked: marked.to_s.start_with?(V1_MARKER))
    return sdl unless link

    declare(document_ast, sdl, link)
    add_service(document_ast, link)
    document_ast.to_sdl
  end

  # The definitions of the spec's directives the SDL uses and does not
  # declare, and of the types they refer to.
  def declare(document_ast, sdl, link)
    used = sdl.scan(/@(\w+)/).flatten.to_set
    used << 'link' if link.v2?
    definitions = Definitions.directives(link).select { |name, _| used.include?(name) && !document_ast.directives.key?(name) }
    definitions.each_value { |definition| document_ast.add(parse(definition).definitions.first) }

    text = definitions.values.join("\n")
    Definitions.types(link).each do |name, definition|
      document_ast.define_type(name, definition) if text.match?(/\b#{name}\b/)
    end
  end

  def add_service(document_ast, link)
    document_ast.define_type('_Any', 'scalar _Any')
    document_ast.define_type('_Service', 'type _Service { sdl: String! }')
    query = document_ast.types['Query'] || Nodes::ObjectTypeDefinition.new(name: 'Query', fields: [], interfaces: [], directives: [])
    fields = query.fields.reject { |field| FIELDS.include?(field.name) }
    entities = entity_types(document_ast, link)
    if entities.any?
      document_ast.put_type(parse("union _Entity = #{entities.join(' | ')}").definitions.first)
      fields << root_field("#{ENTITIES_FIELD}(representations: [_Any!]!): [_Entity]!")
    end
    fields << root_field("#{SERVICE_FIELD}: _Service!")
    document_ast.put_type(query.merge(fields: fields))
  end

  # The object types with @key, which `_entities` may answer.
  def entity_types(document_ast, link)
    key = link.directive('key')
    document_ast.types.values.select do |type|
      type.is_a?(Nodes::ObjectTypeDefinition) && type.directives.any? { |directive| directive.name == key }
    end.map(&:name)
  end

  def root_field(sdl)
    parse("type Query { #{sdl} }").definitions.first.fields.first
  end

  def parse(sdl)
    ::GraphQL::Language::Parser.parse(sdl)
  end

  # Is `schema` a subgraph Lighthouse built?
  def subgraph?(schema)
    !!schema.query&.get_field(SERVICE_FIELD)
  end

  # The Link of a subgraph Lighthouse built (Federation 1 without one).
  def schema_link(schema)
    schema.respond_to?(:federation_link) ? schema.federation_link : Link.v1
  end

  # After the schema is built from `document`: resolve `_service` and
  # `_entities`, and answer `federation_sdl` as subgraph schemas do.
  def apply(schema, document)
    return unless subgraph?(schema)

    link = Link.from_document(document) || Link.v1
    schema.define_singleton_method(:federation_link) { link }
    query = schema.query
    query.define_singleton_method("resolve_field_#{SERVICE_FIELD}") do |_obj, _args, ctx|
      { sdl: Lighthouse::GraphQL::Federation::Printer.print(ctx.schema) }
    end
    if query.get_field(ENTITIES_FIELD)
      query.define_singleton_method("resolve_field_#{ENTITIES_FIELD}") do |_obj, args, ctx|
        Lighthouse::GraphQL::Federation::Entities.resolve(Lighthouse::Support::Naming.fetch_arg(args, 'representations'), ctx)
      end
    end
    FIELDS.each do |name|
      field = query.get_field(name)
      Lighthouse::GraphQL::GeneratedResolvers.route_runtime_resolver(query, field) if field
    end
    schema.define_singleton_method(:federation_sdl) { |**| Lighthouse::GraphQL::Federation::Printer.print(self) }
  end
end
