# frozen_string_literal: true

# The types @orderBy generates for an argument written with the `_`
# placeholder, as PHP Lighthouse's OrderByDirective and OrderByServiceProvider
# define them. For Query.posts(orderBy:), the prefix is QueryPostsOrderBy:
#
#   no columns:/columnsEnum:/relations:  [OrderByClause!]           column: String!, order: SortOrder!
#   columns: / columnsEnum:              [<Prefix>OrderByClause!]   column: <Prefix>Column! (or the columnsEnum)
#   relations:                           [<Prefix>RelationOrderByClause!]
#     column: <Prefix>Column (or String), order: SortOrder!, and per relation
#     <relation>: <Prefix><Relation> { aggregate: COUNT } or, with the relation's
#     own columns:, { aggregate: AVG|MIN|MAX|SUM|COUNT, column: <Prefix><Relation>Column }
class Lighthouse::OrderBy::Types
  GeneratedTypes = Lighthouse::GraphQL::Directives::GeneratedTypes

  DEFAULT_CLAUSE = 'OrderByClause'
  SORT_ORDER = 'SortOrder'
  AGGREGATE = 'OrderByRelationAggregateFunction'
  AGGREGATE_WITH_COLUMN = 'OrderByRelationWithColumnAggregateFunction'

  SDL = {
    SORT_ORDER => <<~GRAPHQL,
      "Directions for ordering a list of records."
      enum SortOrder {
        "Sort records in ascending order."
        ASC

        "Sort records in descending order."
        DESC
      }
    GRAPHQL
    AGGREGATE => <<~GRAPHQL,
      "Aggregate functions when ordering by a relation without specifying a column."
      enum OrderByRelationAggregateFunction {
        "Amount of items."
        COUNT @enum(value: "count")
      }
    GRAPHQL
    AGGREGATE_WITH_COLUMN => <<~GRAPHQL
      "Aggregate functions when ordering by a relation that may specify a column."
      enum OrderByRelationWithColumnAggregateFunction {
        "Average."
        AVG @enum(value: "avg")

        "Minimum."
        MIN @enum(value: "min")

        "Maximum."
        MAX @enum(value: "max")

        "Sum."
        SUM @enum(value: "sum")

        "Amount of items."
        COUNT @enum(value: "count")
      }
    GRAPHQL
  }.freeze

  def initialize(document_ast, directive, arg, field, type)
    @document_ast = document_ast
    @directive = directive
    @relations = Array(GeneratedTypes.directive_value(directive, 'relations')).map { |relation| relation.transform_keys(&:to_s) }
    @arg = arg
    @path = "#{type.name}.#{field.name}.#{arg.name}"
    @prefix = GeneratedTypes.qualified_arg_type(arg, field, type)
    @columns_enum = -> { GeneratedTypes.columns_enum(document_ast, directive, arg, field, type) }
  end

  # The argument, typed with the clauses generated for it.
  def argument
    @document_ast.define_type(SORT_ORDER, SDL[SORT_ORDER])
    arg = GeneratedTypes.describe(@arg, "Order by clause for #{@path}.")
    allowed = GeneratedTypes.allowed_columns?(@directive)
    column_type = allowed ? @columns_enum.call : 'String'

    clause =
      if @relations.any? then relation_clause(column_type)
      elsif allowed then column_clause("#{@prefix}OrderByClause", column_type, "Order by clause for #{@path}.")
      else column_clause(DEFAULT_CLAUSE, 'String', 'Allows ordering a list of records.')
      end
    GeneratedTypes.replace_placeholder(arg, "[#{clause}!]")
  end

  private

  def column_clause(name, column_type, description)
    define(name, description, ["column: #{column_type}!", 'The column that is used for ordering.'], order_field)
  end

  # A column, or one relation's aggregate.
  def relation_clause(column_type)
    aggregates = @relations.map { |relation| ["#{relation['relation']}: #{aggregate_input(relation)}", 'Aggregate specification.'] }
    define("#{@prefix}RelationOrderByClause", "Order by clause for #{@path}.",
           ["column: #{column_type}", 'The column that is used for ordering.'], order_field, *aggregates)
  end

  # COUNT, or, with the relation's `columns:` / `columnsEnum:`, an aggregate of one of its columns.
  def aggregate_input(relation)
    name = "#{@prefix}#{GeneratedTypes.studly(relation['relation'])}"
    columns_enum = relation_columns_enum(relation, name)
    aggregate = columns_enum ? AGGREGATE_WITH_COLUMN : AGGREGATE
    @document_ast.define_type(aggregate, SDL[aggregate])

    fields = if columns_enum
               [["aggregate: #{aggregate}!", 'The aggregate function to apply to the column.'],
                ["column: #{columns_enum}", 'Name of the column to use.']]
             else
               [["aggregate: #{aggregate}!", 'Always COUNT.']]
             end
    define(name, "Aggregate specification for #{@path}.#{relation['relation']}.", *fields)
  end

  def relation_columns_enum(relation, name)
    if relation['columns'] && relation['columnsEnum']
      raise Lighthouse::DefinitionError,
            "The relation #{relation['relation']} of @orderBy on #{@path} can only have one of the following arguments: `columns`, `columnsEnum`."
    end
    return relation['columnsEnum'] if relation['columnsEnum']
    return nil unless relation['columns']

    GeneratedTypes.define_columns_enum(@document_ast, "#{name}Column", relation['columns'], "#{@path}.#{relation['relation']}")
    "#{name}Column"
  end

  def order_field
    ["order: #{SORT_ORDER}!", 'The direction that is used for ordering.']
  end

  # Defines the input `name` with `fields`, each [SDL, description]; returns its name.
  def define(name, description, *fields)
    @document_ast.define_type(name) do
      %("#{description}"\ninput #{name} {\n#{fields.map { |sdl, doc| %(  "#{doc}"\n  #{sdl}) }.join("\n\n")}\n}\n)
    end
    name
  end
end
