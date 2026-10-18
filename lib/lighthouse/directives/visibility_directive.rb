# frozen_string_literal: true

# @hide(env:) and @show(env:) — leave a field out of the schema in some
# environments, as PHP Lighthouse's directives: @hide removes it in the ones
# listed, @show keeps it only in those. The environment is Rails.env (see
# Support::Environment); the SDL is rewritten before the schema is built.
#
#   type Query {
#     debugInfo: String @show(env: ["development", "test"])
#     legacyFeed: [Post!]! @hide(env: ["production"]) @all
#   }
class Lighthouse::GraphQL::Directives::VisibilityDirective
  DEFINITIONS = {
    'hide' => <<~GRAPHQL.chomp,
      """
      Excludes the annotated element from the schema conditionally.
      """
      directive @hide(
        "Specify which environments must not use this field, e.g. [\\"production\\"]."
        env: [String!]!
      ) on FIELD_DEFINITION
    GRAPHQL
    'show' => <<~GRAPHQL.chomp
      """
      Includes the annotated element in the schema conditionally.
      """
      directive @show(
        "Specify which environments may use this field, e.g. [\\"testing\\"]."
        env: [String!]!
      ) on FIELD_DEFINITION
    GRAPHQL
  }.freeze

  FIELDS = [
    ::GraphQL::Language::Nodes::ObjectTypeDefinition, ::GraphQL::Language::Nodes::ObjectTypeExtension,
    ::GraphQL::Language::Nodes::InterfaceTypeDefinition, ::GraphQL::Language::Nodes::InterfaceTypeExtension
  ].freeze

  DECLARATION = /directive\s+@(hide|show)\b/
  USAGE = /@(hide|show)\b/

  def self.manipulate(sdl)
    return sdl unless sdl.is_a?(String) && sdl.gsub(DECLARATION, '').match?(USAGE)

    document = ::GraphQL::Language::Parser.parse(sdl)
    env = Lighthouse::Support::Environment.current
    ::GraphQL::Language::Printer.new.print(document.merge(definitions: document.definitions.map { |definition| visible_fields(definition, env) }))
  rescue ::GraphQL::ParseError
    sdl
  end

  def self.visible_fields(definition, env)
    return definition unless FIELDS.any? { |kind| definition.is_a?(kind) }

    definition.merge(fields: definition.fields.select { |field| visible?(field, env) })
  end

  def self.visible?(field, env)
    field.directives.all? do |directive|
      case directive.name
      when 'hide' then environments(directive).exclude?(env)
      when 'show' then environments(directive).include?(env)
      else true
      end
    end
  end

  def self.environments(directive)
    Array(directive.arguments.find { |argument| argument.name == 'env' }&.value).map(&:to_s)
  end
end
