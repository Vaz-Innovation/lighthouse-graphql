# frozen_string_literal: true

# The schema document as the manipulation phase works on it, as PHP
# Lighthouse's DocumentAST: the type definitions by name, the type extensions
# by the name they extend, the directive definitions and the schema
# definition/extensions.
#
# A type is defined once. A second definition of the same name is an error,
# not a merge: add to a type from another file with `extend type` (or
# `extend input`, `extend enum`, ...), which ASTBuilder merges into it.
#
# graphql-ruby's nodes are immutable, so a manipulation replaces a type with
# `put_type(type.merge(...))` rather than editing it.
class Lighthouse::GraphQL::DocumentAST
  Nodes = ::GraphQL::Language::Nodes

  # The SDL keyword each kind of definition is extended with.
  KEYWORDS = {
    Nodes::ObjectTypeDefinition => 'type',
    Nodes::InterfaceTypeDefinition => 'interface',
    Nodes::InputObjectTypeDefinition => 'input',
    Nodes::EnumTypeDefinition => 'enum',
    Nodes::UnionTypeDefinition => 'union',
    Nodes::ScalarTypeDefinition => 'scalar'
  }.freeze

  EXTENSIONS = [
    Nodes::ObjectTypeExtension, Nodes::InterfaceTypeExtension, Nodes::InputObjectTypeExtension,
    Nodes::EnumTypeExtension, Nodes::UnionTypeExtension, Nodes::ScalarTypeExtension
  ].freeze

  attr_reader :types, :type_extensions, :directives, :schema_definitions

  def self.from_source(sdl)
    document = begin
      ::GraphQL::Language::Parser.parse(sdl.to_s)
    rescue ::GraphQL::ParseError => e
      raise Lighthouse::DefinitionError, "The schema is not valid GraphQL: #{e.message}"
    end
    from_document(document)
  end

  def self.from_document(document)
    new.tap { |ast| document.definitions.each { |definition| ast.add(definition) } }
  end

  def initialize
    @types = {}
    @type_extensions = Hash.new { |hash, name| hash[name] = [] }
    @directives = {}
    @schema_definitions = []
  end

  def add(definition)
    case definition
    when *KEYWORDS.keys then add_type(definition)
    when *EXTENSIONS then @type_extensions[definition.name] << definition
    when Nodes::DirectiveDefinition then add_directive(definition)
    when Nodes::SchemaDefinition, Nodes::SchemaExtension then @schema_definitions << definition
    else raise Lighthouse::DefinitionError, "Unknown definition type: #{definition.class}"
    end
  end

  # Adds a type, or replaces the definition of the same name.
  def put_type(definition)
    @types[definition.name] = definition
    self
  end

  # Drops the type of that name, if any.
  def remove_type(name)
    @types.delete(name)
    self
  end

  # Adds the type parsed from `sdl`, unless the document has a type of that name.
  def define_type(name, sdl = nil)
    return @types[name] if @types.key?(name)

    definition = ::GraphQL::Language::Parser.parse(sdl || yield).definitions.first
    put_type(definition)
    definition
  end

  def type?(name) = @types.key?(name)

  # The names of the types, as they are now: manipulators add types while
  # ASTBuilder goes over these.
  def type_names = @types.keys

  def to_document
    Nodes::Document.new(definitions: @schema_definitions + @directives.values + @types.values + @type_extensions.values.flatten)
  end

  def to_sdl
    ::GraphQL::Language::Printer.new.print(to_document)
  end

  private

  def add_type(definition)
    if @types.key?(definition.name)
      keyword = KEYWORDS.fetch(definition.class)
      raise Lighthouse::DefinitionError,
            "Duplicate definition #{definition.name} found when parsing the schema. Define a type once and add to it " \
            "from other files with `extend #{keyword} #{definition.name}`."
    end

    @types[definition.name] = definition
  end

  def add_directive(definition)
    raise Lighthouse::DefinitionError, "Duplicate definition @#{definition.name} found when parsing the schema." if @directives.key?(definition.name)

    @directives[definition.name] = definition
  end
end
