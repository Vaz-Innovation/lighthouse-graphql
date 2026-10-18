# frozen_string_literal: true

require_relative 'where_conditions_base'

# @whereHasConditions: the records with a related record matching the
# client's conditions.
#
#   users(hasPosts: _ @whereHasConditions(columns: ["title"])): [User!]! @all
#   { users(hasPosts: { column: TITLE, value: "Notes" }) { name } }
class Lighthouse::GraphQL::Directives::Arguments::WhereHasConditions < Lighthouse::GraphQL::Directives::Arguments::WhereConditionsBase
  SUFFIX = 'WhereHasConditions'
  DESCRIPTION = 'Filter results by related records conditions.'

  DEFINITION = <<~GRAPHQL.chomp
    """
    Allows clients to filter a query based on the existence of a related model, using
    a dynamically controlled `WHERE` condition that applies to the relationship.
    """
    directive @whereHasConditions(
      """
      The relationship that the conditions will be applied to.
      This argument can be omitted if the argument name follows the naming
      convention `has{$RELATION}`. For example, if the relationship
      is named `posts`, the argument name must be `hasPosts`.
      """
      relation: String

    #{COLUMN_ARGUMENTS.gsub(/^/, '  ')}
    ) on ARGUMENT_DEFINITION
  GRAPHQL

  def self.directive_name = 'whereHasConditions'

  def self.definition = DEFINITION

  private

  # The records with at least one related record matching the value (`{}`: any related record).
  def conditions(value)
    condition = value.respond_to?(:to_h) ? value.to_h : value
    {
      has: {
        relation: relation_name,
        operator: Lighthouse::WhereConditions::Types::DEFAULT_HAS_OPERATOR,
        amount: Lighthouse::WhereConditions::Types::DEFAULT_HAS_AMOUNT,
        condition: condition.presence
      }
    }
  end

  # `relation:`, else the argument name without its `has` prefix: hasPosts -> posts.
  def relation_name
    Lighthouse::Support::DirectiveArgs.literal(@directive_node, 'relation') ||
      @arg_node.name.sub(/\Ahas(?=[A-Z_])/, '').then { |name| name[0].downcase + name[1..] }
  end
end
