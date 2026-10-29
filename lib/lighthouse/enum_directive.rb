# frozen_string_literal: true

# @enum(value:) — the internal value of an enum value, as PHP Lighthouse's
# directive: what a resolver gets for it in an argument, and what it answers
# with in a result.
#
#   enum Role {
#     ADMIN @enum(value: "admin")
#     MEMBER @enum(value: "member")
#   }
#
# `users(role: Role @eq)` then filters on "admin", and a User whose role is
# "admin" answers ADMIN. Without the directive, a value is its own name.
module Lighthouse::GraphQL::EnumDirective
  DEFINITION = <<~GRAPHQL.chomp
    """
    Assign an internal value to an enum key.
    When dealing with the Enum type in your code,
    you will receive the defined value instead of the string key.
    """
    directive @enum(
      "The internal value of the enum key."
      value: Mixed
    ) on ENUM_VALUE
  GRAPHQL

  TYPE_DEFINITIONS = {
    'Mixed' => <<~GRAPHQL.chomp
      "Loose type that allows any value. Be careful when passing in large JSON objects, as it may result in poor performance."
      scalar Mixed
    GRAPHQL
  }.freeze

  module_function

  def apply(schema)
    schema.types.each_value { |type| apply_to(type) if type.kind.enum? }
  end

  def apply_to(enum_type)
    enum_type.values.each_value do |enum_value|
      directive = (enum_value.ast_node&.directives || []).find { |d| d.name == 'enum' }
      enum_value.value(Lighthouse::Support::DirectiveArgs.literal(directive, 'value')) if directive
    end
  end
end
