# frozen_string_literal: true

# The manipulation phase, as PHP Lighthouse's ASTBuilder runs it on the
# stitched schema:
#
# 1. DocumentAST.from_source: every type defined once.
# 2. The SDL's definitions of graphql-ruby's built-in directives (@skip,
#    @include, @deprecated, @oneOf, @specifiedBy) dropped: see BUILT_IN_DIRECTIVES.
# 3. Type extensions merged into the types they extend. An extension of a
#    root type that has no definition (`extend type Query` alone) defines it.
# 4. The type and field manipulators: @hide/@show, @model, @paginate (and the
#    relation directives' `type:`), @softDeletes, @node.
# 5. The argument manipulators: each argument directive whose class includes
#    Contracts::ArgManipulator rewrites its argument (@whereConditions,
#    @whereHasConditions, @orderBy turn `_` into the input types they generate).
# 6. `scalar _`, if the SDL declares it for the IDE, dropped: nothing is left of the placeholder.
# 7. The definitions of directives the generated types use (`@enum`).
#
# Returns the manipulated SDL; ManipulateAST listeners then see its document.
module Lighthouse::GraphQL::ASTBuilder
  Nodes = ::GraphQL::Language::Nodes

  EXTENSION_TO_DEFINITION = {
    Nodes::ObjectTypeExtension => Nodes::ObjectTypeDefinition,
    Nodes::InterfaceTypeExtension => Nodes::InterfaceTypeDefinition,
    Nodes::InputObjectTypeExtension => Nodes::InputObjectTypeDefinition,
    Nodes::EnumTypeExtension => Nodes::EnumTypeDefinition,
    Nodes::UnionTypeExtension => Nodes::UnionTypeDefinition,
    Nodes::ScalarTypeExtension => Nodes::ScalarTypeDefinition
  }.freeze

  # What each extension adds to its definition, besides directives.
  MERGED_LISTS = {
    Nodes::ObjectTypeExtension => %i[fields interfaces],
    Nodes::InterfaceTypeExtension => %i[fields interfaces],
    Nodes::InputObjectTypeExtension => %i[fields],
    Nodes::EnumTypeExtension => %i[values],
    Nodes::UnionTypeExtension => %i[types],
    Nodes::ScalarTypeExtension => []
  }.freeze

  ROOT_TYPES = %w[Query Mutation Subscription].freeze

  OBJECT_LIKE = [Nodes::ObjectTypeDefinition, Nodes::InterfaceTypeDefinition].freeze

  # graphql-ruby's classes for these do the work: @skip skips, @oneOf makes the
  # input object accept exactly one field. A definition in the SDL (copied from
  # a printed schema, or from a graphql-js project, where it is harmless) would
  # replace the class with a plain directive of the same name, which does nothing.
  BUILT_IN_DIRECTIVES = ::GraphQL::Schema.default_directives.keys.freeze

  module_function

  def build(sdl, registry: Lighthouse::DirectiveRegistry.default)
    document_ast = Lighthouse::GraphQL::DocumentAST.from_source(sdl)
    BUILT_IN_DIRECTIVES.each { |name| document_ast.remove_directive(name) }
    extend_types(document_ast)

    document_ast = Lighthouse::GraphQL::DocumentAST.from_source(registry.manipulate_sdl(document_ast.to_sdl))
    apply_arg_manipulators(document_ast, registry)
    # `scalar _` is for the IDE (IdeHelper); the executable schema has no placeholder.
    document_ast.remove_type(Lighthouse::GraphQL::Directives::GeneratedTypes::PLACEHOLDER)

    Lighthouse::GraphQL::SchemaGenerator.inject_directive_definitions(document_ast.to_sdl)
  end

  def extend_types(document_ast)
    document_ast.type_extensions.each do |name, extensions|
      extensions.each { |extension| extend_type(document_ast, name, extension) }
    end
    document_ast.type_extensions.clear
  end

  def extend_type(document_ast, name, extension)
    definition = document_ast.types[name] || root_type(document_ast, name, extension)
    unless definition.is_a?(EXTENSION_TO_DEFINITION.fetch(extension.class))
      raise Lighthouse::DefinitionError,
            "The type extension #{name} of kind #{kind(extension)} can not extend a definition of kind #{kind(definition)}."
    end

    merged = MERGED_LISTS.fetch(extension.class).index_with { |list| merge_unique(definition.public_send(list), extension.public_send(list)) }
    document_ast.put_type(definition.merge(directives: definition.directives + extension.directives, **merged))
  end

  # `extend type Query` with no `type Query` anywhere defines it, as in PHP Lighthouse.
  def root_type(document_ast, name, extension)
    unless ROOT_TYPES.include?(name) && extension.is_a?(Nodes::ObjectTypeExtension)
      raise Lighthouse::DefinitionError, "Could not find a base definition #{name} of kind #{kind(extension)} to extend."
    end

    Nodes::ObjectTypeDefinition.new(name: name, fields: [], interfaces: [], directives: []).tap { |root| document_ast.put_type(root) }
  end

  # The definition's nodes followed by the extension's; a name in both is an error.
  def merge_unique(original, addition)
    names = addition.to_set(&:name)
    duplicate = original.find { |node| names.include?(node.name) }
    raise Lighthouse::DefinitionError, "Duplicate definition #{duplicate.name} found when merging." if duplicate

    original + addition
  end

  def kind(node)
    node.class.name.demodulize
  end

  # Every argument of every object and interface field, through the
  # manipulators of the directives it carries, in their SDL order.
  def apply_arg_manipulators(document_ast, registry)
    document_ast.type_names.each do |name|
      type = document_ast.types[name]
      next unless OBJECT_LIKE.any? { |kind| type.is_a?(kind) }

      fields = type.fields.map do |field|
        field.merge(arguments: field.arguments.map { |arg| manipulate_argument(document_ast, registry, arg, field, type) })
      end
      document_ast.put_type(type.merge(fields: fields))
    end
  end

  def manipulate_argument(document_ast, registry, arg, field, type)
    manipulated = arg.directives.reduce(arg) do |current, directive|
      manipulator = registry.arg_manipulator_class(directive.name)
      manipulator ? manipulator.new(current, directive).manipulate_arg_definition(document_ast, field, type) : current
    end
    return manipulated unless placeholder?(manipulated.type)

    raise Lighthouse::DefinitionError,
          "#{type.name}.#{field.name}(#{arg.name}:) has the placeholder type `_`, which only a directive that generates " \
          'its type replaces: @whereConditions, @whereHasConditions or @orderBy.'
  end

  def placeholder?(type)
    Lighthouse::GraphQL::Directives::GeneratedTypes.placeholder?(type)
  end
end
