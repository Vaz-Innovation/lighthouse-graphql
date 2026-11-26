# frozen_string_literal: true

# The schema's link to the Apollo Federation spec, as a subgraph declares it:
#
#   extend schema @link(url: "https://specs.apollo.dev/federation/v2.9", import: ["@key", "@shareable"])
#
# It says which version of Federation the subgraph speaks, and what the spec's
# directives and types are called in it: an imported one keeps its name (or
# the one `{ name: "@key", as: "@primaryKey" }` gives it), any other is
# prefixed with the link's namespace (`@federation__key`, or `as:`'s). A
# schema without the link is a Federation 1 subgraph (`federation: true`),
# whose directives have no prefix, as in PHP Lighthouse.
class Lighthouse::GraphQL::Federation::Link
  URL = %r{\Ahttps://specs\.apollo\.dev/federation/v(\d+)\.(\d+)\z}

  Nodes = ::GraphQL::Language::Nodes

  attr_reader :version, :namespace

  # The link in the document's `schema` / `extend schema` directives, or nil.
  def self.from_document(document)
    document.definitions.each do |definition|
      next unless definition.is_a?(Nodes::SchemaDefinition) || definition.is_a?(Nodes::SchemaExtension)

      definition.directives.each do |directive|
        link = from_directive(directive)
        return link if link
      end
    end
    nil
  end

  def self.from_directive(directive)
    return unless directive.name == 'link'

    url = Lighthouse::Support::DirectiveArgs.literal(directive, 'url').to_s
    match = URL.match(url)
    return unless match

    new(version: [match[1].to_i, match[2].to_i],
        namespace: Lighthouse::Support::DirectiveArgs.literal(directive, 'as') || 'federation',
        imports: Lighthouse::Support::DirectiveArgs.literal(directive, 'import'))
  end

  # A Federation 1 subgraph: no link, every name as the spec writes it.
  def self.v1
    new(version: [1, 0], namespace: nil, imports: nil)
  end

  def initialize(version:, namespace:, imports:)
    @version = version
    @namespace = namespace
    @imports = parse_imports(imports)
  end

  def v2? = version.first >= 2

  # The name the spec's directive `name` (no `@`) has in this schema.
  def directive(name)
    local(name, "@#{name}")&.delete_prefix('@')
  end

  # The name the spec's type `name` (`FieldSet`) has in this schema.
  def type(name)
    return "_#{name}" unless v2?

    local(name, name)
  end

  private

  def local(name, element)
    return name unless v2?

    @imports.fetch(element) { "#{namespace}__#{name}" }
  end

  # { "@key" => "@key", "@shareable" => "@share", "FieldSet" => "FieldSet" }
  def parse_imports(imports)
    Array(imports).to_h do |import|
      if import.is_a?(Hash)
        import = import.transform_keys(&:to_s)
        [import['name'].to_s, (import['as'] || import['name']).to_s]
      else
        [import.to_s, import.to_s]
      end
    end
  end
end
