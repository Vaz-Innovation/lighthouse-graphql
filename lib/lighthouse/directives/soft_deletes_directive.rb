# frozen_string_literal: true

# Schema side of @softDeletes, as PHP Lighthouse does it: a field carrying it
# gains the `trashed` argument (see Arguments::Trashed for what it does), and
# the directive is consumed.
#
#   tasks: [Task!]! @all @softDeletes   ->   tasks(trashed: Trashed @trashed): [Task!]! @all
#
# `ability:` puts a @canModel on the argument, so only who the policy allows
# may use it (Lighthouse's, not PHP Lighthouse's):
#
#   tasks: [Task!]! @all @softDeletes(ability: "view_trashed")
#     ->   tasks(trashed: Trashed @trashed @canModel(ability: "view_trashed")): [Task!]! @all
#
# The `Trashed` enum is added once whenever a `@trashed` argument is in the
# schema (generated here or written by hand), unless the app declares its own.
class Lighthouse::GraphQL::Directives::SoftDeletesDirective
  DEFINITIONS = {
    'softDeletes' => <<~GRAPHQL.chomp
      """
      Allows to filter if trashed elements should be fetched.
      This manipulates the schema by adding the argument
      `trashed: Trashed @trashed` to the field.
      """
      directive @softDeletes(
        "The policy ability a user needs to pass `trashed` (a @canModel on it). Without it, anyone may."
        ability: String
      ) on FIELD_DEFINITION
    GRAPHQL
  }.freeze

  TRASHED_ENUM = <<~GRAPHQL.chomp
    "Specify if you want to include or exclude trashed results from a query."
    enum Trashed {
      "Only return trashed results."
      ONLY
      "Return both trashed and non-trashed results."
      WITH
      "Only return non-trashed results."
      WITHOUT
    }
  GRAPHQL

  ARGUMENT = %(type T { f("Specify if you want to include or exclude trashed results from a query." trashed: Trashed @trashed): Int })

  FIELD_DEFINITIONS = [
    ::GraphQL::Language::Nodes::ObjectTypeDefinition,
    ::GraphQL::Language::Nodes::ObjectTypeExtension,
    ::GraphQL::Language::Nodes::InterfaceTypeDefinition,
    ::GraphQL::Language::Nodes::InterfaceTypeExtension
  ].freeze

  INPUT_DEFINITIONS = [
    ::GraphQL::Language::Nodes::InputObjectTypeDefinition,
    ::GraphQL::Language::Nodes::InputObjectTypeExtension
  ].freeze

  # The directives' own definitions are in every injected SDL; usage is what counts.
  DECLARATION = /directive\s+@(softDeletes|trashed)\b/
  USAGE = /@(softDeletes|trashed)\b/

  def self.manipulate(sdl)
    return sdl unless sdl.is_a?(String) && sdl.gsub(DECLARATION, '').match?(USAGE)

    document = parse(sdl)
    document ? new(document).manipulate(sdl) : sdl
  end

  def self.parse(sdl)
    ::GraphQL::Language::Parser.parse(sdl)
  rescue ::GraphQL::ParseError => e
    warn("Lighthouse soft deletes: parse failed: #{e.message}")
    nil
  end
  private_class_method :parse

  def initialize(document)
    @document = document
    @rewritten = false
    @trashed = false
  end

  # The SDL with the `trashed` arguments added and `Trashed` defined. Left
  # untouched when there is nothing to rewrite.
  def manipulate(sdl)
    definitions = @document.definitions.map { |definition| rewrite(definition) }
    printed = @rewritten ? ::GraphQL::Language::Printer.new.print(@document.merge(definitions: definitions)) : sdl
    @trashed && !enum_declared? ? "#{printed}\n\n#{TRASHED_ENUM}" : printed
  end

  private

  def rewrite(definition)
    if FIELD_DEFINITIONS.any? { |kind| definition.is_a?(kind) }
      definition.merge(fields: definition.fields.map { |field| soft_delete(field) })
    else
      note_input_arguments(definition)
      definition
    end
  end

  # A hand-written @trashed on an input field needs the enum too.
  def note_input_arguments(definition)
    return unless INPUT_DEFINITIONS.any? { |kind| definition.is_a?(kind) }

    @trashed = true if definition.fields.any? { |field| trashed?(field) }
  end

  def soft_delete(field)
    directive = field.directives.find { |node| node.name == 'softDeletes' }
    if directive
      @rewritten = true
      field = field.merge(arguments: with_trashed_argument(field.arguments, ability(directive)),
                          directives: field.directives.reject { |node| node.name == 'softDeletes' })
    end
    @trashed ||= field.arguments.any? { |argument| trashed?(argument) }
    field
  end

  # The field's arguments with `trashed`, unless it has one of its own;
  # behind @canModel(ability:) when `ability` is given.
  def with_trashed_argument(arguments, ability)
    return arguments if arguments.any? { |argument| argument.name == 'trashed' }

    sdl = ability ? ARGUMENT.sub('@trashed', "@trashed @canModel(ability: #{ability.to_json})") : ARGUMENT
    arguments + ::GraphQL::Language::Parser.parse(sdl).definitions.first.fields.first.arguments
  end

  def ability(directive)
    Lighthouse::Support::DirectiveArgs.literal(directive, 'ability')
  end

  def trashed?(node)
    node.directives.any? { |directive| directive.name == 'trashed' }
  end

  def enum_declared?
    @document.definitions.any? { |definition| definition.is_a?(::GraphQL::Language::Nodes::EnumTypeDefinition) && definition.name == 'Trashed' }
  end
end
