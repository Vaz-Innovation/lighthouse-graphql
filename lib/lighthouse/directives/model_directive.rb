# frozen_string_literal: true

# @model(class: "Post") — map an object type to the ActiveRecord model whose
# records it resolves, as PHP Lighthouse's directive, for when the type's name
# is not the model's:
#
#   type Article @model(class: "Post") { id: ID! title: String! }
#
#   type Query {
#     articles: [Article!]! @paginate      # pages through Post
#     article(id: ID! @eq): Article @find   # Post.find_by(id:)
#   }
#
# - Every directive that takes `model:` (@all, @find, @first, @paginate, @create,
#   @update, @upsert, @delete, @can*, ...) on a field returning the type gets it,
#   unless it names its own: the SDL is rewritten before the schema is built.
# - A union or interface resolves a record of the model to the type.
# - @node finds the type's records in the model.
# - The schema does not build unless the class is an ActiveRecord model, and a
#   type class's methods (Types::ArticleType) only run on its records.
class Lighthouse::GraphQL::Directives::ModelDirective
  DEFINITIONS = {
    'model' => <<~GRAPHQL.chomp
      """
      Map a model class to an object type.
      This can be used when the name of the model differs from the name of the type.
      """
      directive @model(
        "The class name of the corresponding model."
        class: String!
      ) on OBJECT
    GRAPHQL
  }.freeze

  OBJECTS = [::GraphQL::Language::Nodes::ObjectTypeDefinition, ::GraphQL::Language::Nodes::ObjectTypeExtension].freeze

  DECLARATION = /directive\s+@model\b/
  USAGE = /@model\b/

  def self.manipulate(sdl)
    return sdl unless sdl.is_a?(String) && sdl.gsub(DECLARATION, '').match?(USAGE)

    new(::GraphQL::Language::Parser.parse(sdl)).manipulate(sdl)
  rescue ::GraphQL::ParseError
    sdl
  end

  # The model class name a schema type maps to with @model, or nil.
  def self.class_name(type)
    directive = (type.ast_node&.directives || []).find { |d| d.name == 'model' }
    directive && Lighthouse::Support::DirectiveArgs.literal(directive, 'class')
  end

  # The model of a schema type: the one @model names, else the one named after it.
  def self.model_for(type)
    Lighthouse::Support::ModelResolver.constantize(class_name(type) || type.graphql_name)
  end

  # The model @model declares on a schema type, or nil.
  def self.declared_model(type)
    name = class_name(type)
    name && Lighthouse::Support::ModelResolver.constantize(name)
  end

  # Fail at build time: every @model names an ActiveRecord model.
  def self.validate!(schema)
    schema.types.each_value do |type|
      name = type.kind.object? && class_name(type)
      next unless name

      model = declared_model(type)
      next if model.is_a?(Class) && defined?(::ActiveRecord::Base) && model < ::ActiveRecord::Base

      raise Lighthouse::DefinitionError, "@model(class: #{name.inspect}) on #{type.graphql_name} names no ActiveRecord model."
    end
  end

  # The directives that take `model:` and act on a field, from the registry.
  def self.model_directives
    Lighthouse::DirectiveRegistry.default.directive_definitions
                                 .select { |_, definition| definition.match?(/\bmodel:/) && definition.include?('FIELD_DEFINITION') }.keys
  end

  def initialize(document)
    @document = document
    @models = document.definitions.filter_map { |definition| [definition.name, model_name(definition)] if object?(definition) }
                      .select(&:last).to_h
    @directives = self.class.model_directives
  end

  def manipulate(sdl)
    return sdl if @models.empty?

    definitions = @document.definitions.map { |definition| object?(definition) ? with_models(definition) : definition }
    ::GraphQL::Language::Printer.new.print(@document.merge(definitions: definitions))
  end

  private

  def object?(definition)
    OBJECTS.any? { |kind| definition.is_a?(kind) }
  end

  # The class @model names on a type definition, or nil.
  def model_name(definition)
    directive = definition.directives.find { |d| d.name == 'model' }
    directive&.arguments&.find { |argument| argument.name == 'class' }&.value
  end

  def with_models(definition)
    definition.merge(fields: definition.fields.map { |field| with_model(field) })
  end

  # The field's model directives with `model:` set to the model its return type maps to.
  def with_model(field)
    model = @models[unwrap(field.type).name]
    return field unless model

    field.merge(directives: field.directives.map { |directive| with_model_argument(directive, model) })
  end

  def with_model_argument(directive, model)
    return directive unless @directives.include?(directive.name) && directive.arguments.none? { |argument| argument.name == 'model' }

    directive.merge(arguments: directive.arguments + [::GraphQL::Language::Nodes::Argument.new(name: 'model', value: model)])
  end

  def unwrap(type)
    type.respond_to?(:of_type) ? unwrap(type.of_type) : type
  end
end
