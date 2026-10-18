# frozen_string_literal: true

require_relative 'where_conditions_base'

# @whereConditions: the client's conditions on the field's records.
#
#   people(where: _ @whereConditions(columns: ["age", "type"])): [Person!]! @all
#   { people(where: { column: AGE, operator: GT, value: 37 }) { name } }
class Lighthouse::GraphQL::Directives::Arguments::WhereConditions < Lighthouse::GraphQL::Directives::Arguments::WhereConditionsBase
  SUFFIX = 'WhereConditions'
  DESCRIPTION = 'Filter results by field conditions.'

  DEFINITION = <<~GRAPHQL.chomp
    """
    Add a dynamically client-controlled WHERE condition to a fields query.
    """
    directive @whereConditions(
    #{COLUMN_ARGUMENTS.gsub(/^/, '  ')}
    ) on ARGUMENT_DEFINITION
  GRAPHQL

  def self.directive_name = 'whereConditions'

  def self.definition = DEFINITION
end
