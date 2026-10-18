# frozen_string_literal: true

# The types @whereConditions and @whereHasConditions generate, as PHP
# Lighthouse's WhereConditionsServiceProvider defines them. For an argument
# whose input is named N:
#
#   N               column, operator, value, AND, OR, HAS: the conditions
#   NRelation       HAS: a relation, how many of its records (operator, amount), and a condition on them
#   NHasCondition   the condition on the related records: as N, but on any column
#
# Without `columns:` / `columnsEnum:` the argument shares the unrestricted
# WhereConditions (and its WhereConditionsRelation / WhereConditionsHasCondition).
module Lighthouse::WhereConditions::Types
  DEFAULT = 'WhereConditions'
  SQL_OPERATOR = 'SQLOperator'
  MIXED = 'Mixed'

  # The SQLOperator enum: what a condition compares the column with.
  OPERATORS = {
    'EQ' => 'Equal operator (`=`)',
    'NEQ' => 'Not equal operator (`!=`)',
    'GT' => 'Greater than operator (`>`)',
    'GTE' => 'Greater than or equal operator (`>=`)',
    'LT' => 'Less than operator (`<`)',
    'LTE' => 'Less than or equal operator (`<=`)',
    'LIKE' => 'Simple pattern matching (`LIKE`)',
    'NOT_LIKE' => 'Negation of simple pattern matching (`NOT LIKE`)',
    'IN' => 'Whether a value is within a set of values (`IN`)',
    'NOT_IN' => 'Whether a value is not within a set of values (`NOT IN`)',
    'BETWEEN' => 'Whether a value is within a range of values (`BETWEEN`)',
    'NOT_BETWEEN' => 'Whether a value is not within a range of values (`NOT BETWEEN`)',
    'IS_NULL' => 'Whether a value is null (`IS NULL`)',
    'IS_NOT_NULL' => 'Whether a value is not null (`IS NOT NULL`)'
  }.freeze

  DEFAULT_OPERATOR = 'EQ'
  DEFAULT_HAS_OPERATOR = 'GTE'
  DEFAULT_HAS_AMOUNT = 1

  module_function

  # Defines N, NHasCondition and NRelation, and the SQLOperator and Mixed they use.
  def define(document_ast, name, column_type, path)
    document_ast.define_type(SQL_OPERATOR) { sql_operator }
    document_ast.define_type(MIXED, 'scalar Mixed')
    document_ast.define_type(name) { conditions(name, "Dynamic WHERE conditions for #{path}.", column_type) }
    document_ast.define_type("#{name}HasCondition") do
      conditions("#{name}HasCondition", "Dynamic WHERE HAS conditions for #{path}.", 'String')
    end
    document_ast.define_type("#{name}Relation") { relation(name, "Dynamic HAS conditions for WHERE conditions for #{path}.") }
  end

  def define_default(document_ast)
    define(document_ast, DEFAULT, 'String', 'any column')
  end

  def conditions(name, description, column_type)
    <<~GRAPHQL
      "#{description}"
      input #{name} {
        "The column that is used for the condition."
        column: #{column_type}

        "The operator that is used for the condition."
        operator: #{SQL_OPERATOR} = #{DEFAULT_OPERATOR}

        "The value that is used for the condition."
        value: #{MIXED}

        "A set of conditions that requires all conditions to match."
        AND: [#{name}!]

        "A set of conditions that requires at least one condition to match."
        OR: [#{name}!]

        "Check whether a relation exists. Extra conditions or a minimum amount can be applied."
        HAS: #{name.delete_suffix('HasCondition')}Relation
      }
    GRAPHQL
  end

  def relation(name, description)
    <<~GRAPHQL
      "#{description}"
      input #{name}Relation {
        "The relation that is checked."
        relation: String!

        "The comparison operator to test against the amount."
        operator: #{SQL_OPERATOR} = #{DEFAULT_HAS_OPERATOR}

        "The amount to test."
        amount: Int = #{DEFAULT_HAS_AMOUNT}

        "Additional condition logic."
        condition: #{name}HasCondition
      }
    GRAPHQL
  end

  def sql_operator
    values = OPERATORS.map { |value, description| %(  "#{description}"\n  #{value}) }
    <<~GRAPHQL
      "The available SQL operators that are used to filter query results."
      enum #{SQL_OPERATOR} {
      #{values.join("\n\n")}
      }
    GRAPHQL
  end
end
