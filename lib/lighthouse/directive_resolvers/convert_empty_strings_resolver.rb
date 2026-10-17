# frozen_string_literal: true

require_relative 'base'

# @convertEmptyStringsToNull — replace incoming empty strings with null, as
# PHP Lighthouse's directive of the same name does.
#
#   type Mutation {
#     createPost(title: String @convertEmptyStringsToNull): Post!   # this argument
#     createUser(input: UserInput!): User! @convertEmptyStringsToNull   # every input of the field
#   }
#   input UserInput { name: String @convertEmptyStringsToNull, bio: String }
#
# On a field it applies to all the field's inputs, nested input objects and
# lists included, but leaves a non-null input (`String!`) alone: only placing
# the directive on that argument or input field itself forces the conversion.
# On an input field it applies wherever the input type is used. Setting
# Config.convert_empty_strings_to_null makes every field behave as if it
# carried the directive.
#
# The conversion is a wrapper around the field's resolver (outermost, order
# 6), so every kind of resolver — directives, @field, Queries::/Mutations::
# classes, the default reader — and @validator see the converted arguments,
# and other fields sharing an input type are unaffected. SchemaGenerator
# installs it too, without the directive on the field, when an argument or
# input type it takes carries the directive, or the setting is on.
class Lighthouse::GraphQL::DirectiveResolvers::ConvertEmptyStringsToNullDirectiveResolver < Lighthouse::GraphQL::DirectiveResolvers::BaseDirectiveResolver
  NAME = 'convertEmptyStringsToNull'

  def self.directive_name = NAME

  def self.definition
    <<~GRAPHQL.chomp
      """
      Replaces incoming empty strings `""` with `null`.

      When used upon fields, empty strings for non-nullable inputs will pass unchanged.
      Only explicitly placing this on non-nullable inputs will force the conversion.
      """
      directive @convertEmptyStringsToNull on ARGUMENT_DEFINITION | INPUT_FIELD_DEFINITION | FIELD_DEFINITION
    GRAPHQL
  end

  # Does a field without the directive still convert? Yes when the setting is
  # on, or when an argument or input type it takes carries the directive.
  def self.implicit?(field_def)
    return false if field_def.arguments.empty?

    Lighthouse::Config.convert_empty_strings_to_null || carried?(field_def.arguments)
  end

  def self.explicit?(argument)
    (argument.ast_node&.directives || []).any? { |d| d.name == NAME }
  end

  # Does any argument, at any depth of input types, carry the directive?
  def self.carried?(argument_defs, seen = Set.new)
    argument_defs.each_value.any? do |argument|
      type = argument.type.unwrap
      explicit?(argument) || (type.kind.input_object? && seen.add?(type.graphql_name) && carried?(type.arguments, seen))
    end
  end

  def initialize(field_def, type_def, directive_node, opts = {})
    super
    @active = !directive_node.nil? || Lighthouse::Config.convert_empty_strings_to_null
  end

  def define_resolver(target_type_class)
    me = self
    inner = capture_inner(target_type_class)

    install(target_type_class, lambda do |obj, args, ctx|
      inner.call(obj, me.convert_arguments(args), ctx)
    end)
  end

  # The field's arguments (a Hash keyed by snake_case symbols) with the empty
  # strings replaced. Input objects that change are copied, never mutated.
  def convert_arguments(args)
    return args unless args.is_a?(Hash)

    convert_hash(@field_def.arguments, args, @active)
  end

  private

  def convert_hash(argument_defs, values, active)
    by_keyword = Lighthouse::Support::Arguments.keyword_index(argument_defs)
    values.to_h { |key, value| [key, convert_argument(by_keyword[key.to_sym], value, active)] }
  end

  def convert_argument(argument, value, active)
    return value if argument.nil? || value.nil?

    explicit = self.class.explicit?(argument)
    convert_value(argument.type, value, active || explicit, explicit)
  end

  # `active`: the enclosing field or argument converts its nullable inputs.
  # `force`: this argument itself carries the directive, so non-null ones too.
  def convert_value(type, value, active, force)
    nullable = !type.kind.non_null?
    type = type.of_type unless nullable
    case type.kind.name
    when 'LIST' then convert_list(type.of_type, value, active, force)
    when 'INPUT_OBJECT' then convert_input(type, value, active)
    when 'SCALAR' then convert_scalar(value, force || (active && nullable))
    else value
    end
  end

  def convert_scalar(value, convert)
    convert && value == '' ? nil : value
  end

  def convert_list(item_type, value, active, force)
    return value unless value.is_a?(Array)

    items = value.map { |item| convert_value(item_type, item, active, force) }
    items.zip(value).all? { |new, old| new.equal?(old) } ? value : items
  end

  def convert_input(type, value, active)
    values = value.respond_to?(:to_kwargs) ? value.to_kwargs : value
    return value unless values.is_a?(Hash)

    converted = convert_hash(type.arguments, values, active)
    return value if converted.all? { |key, new| new.equal?(values[key]) }
    return converted unless value.respond_to?(:to_kwargs)

    value.dup.tap { |copy| copy.instance_variable_set(:@ruby_style_hash, converted) }
  end
end
