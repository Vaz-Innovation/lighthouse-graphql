# frozen_string_literal: true

require_relative 'base'

# @orderBy, as PHP Lighthouse's: on an argument, the client orders the result
# by one or more clauses; on a field, the result is always in that order.
#
#   type Query {
#     posts(orderBy: _ @orderBy(columns: ["posted_at", "title"])): [Post!]! @all
#     users(orderBy: _ @orderBy(relations: [{ relation: "posts" }])): [User!]! @all
#     latestPosts: [Post!]! @all @orderBy(column: "posted_at", direction: DESC)
#   }
#
#   { posts(orderBy: [{ column: POSTED_AT, order: DESC }, { column: TITLE, order: ASC }]) { title } }
#   { users(orderBy: [{ posts: { aggregate: COUNT }, order: DESC }]) { name } }
#
# An argument written with the `_` placeholder gets the types generated for
# it (Query.posts(orderBy:) -> [QueryPostsOrderByOrderByClause!]):
#
# - no `columns:` / `columnsEnum:` / `relations:`: the shared OrderByClause, any column;
# - `columns:` / `columnsEnum:`: <QualifiedArgType>OrderByClause, its column one of the enum;
# - `relations:`: <QualifiedArgType>RelationOrderByClause, whose clauses name
#   either a column or a relation's aggregate (COUNT, or AVG/MIN/MAX/SUM of a column).
#
# A relation's aggregate is computed per record in a LEFT JOIN on a grouped
# subquery, so records without related ones are ordered too (a COUNT of 0).
class Lighthouse::GraphQL::Directives::Arguments::OrderBy < Lighthouse::GraphQL::Directives::Arguments::Base
  include Lighthouse::Contracts::ArgManipulator
  include Lighthouse::Contracts::FieldBuilder

  # The Arel node of each OrderByRelation*AggregateFunction value (Arel::Nodes::<name>).
  AGGREGATES = { 'count' => :Count, 'avg' => :Avg, 'min' => :Min, 'max' => :Max, 'sum' => :Sum }.freeze

  DEFINITION = <<~GRAPHQL.chomp
    """
    Sort a result list by one or more given columns.
    """
    directive @orderBy(
      """
      Restrict the allowed column names to a well-defined list.
      This improves introspection capabilities and security.
      Mutually exclusive with `columnsEnum`.
      Only used when the directive is added on an argument.
      """
      columns: [String!]

      """
      Use an existing enumeration type to restrict the allowed columns to a predefined list.
      This allows you to re-use the same enum for multiple fields.
      Mutually exclusive with `columns`.
      Only used when the directive is added on an argument.
      """
      columnsEnum: String

      """
      Allow clients to sort by aggregates on relations.
      Only used when the directive is added on an argument.
      """
      relations: [OrderByRelation!]

      """
      The database column for which the order by clause will be applied on.
      Only used when the directive is added on a field.
      """
      column: String

      """
      The direction of the order by clause.
      Only used when the directive is added on a field.
      """
      direction: OrderByDirection = ASC
    ) on ARGUMENT_DEFINITION | FIELD_DEFINITION
  GRAPHQL

  TYPE_DEFINITIONS = {
    'OrderByDirection' => <<~GRAPHQL.chomp,
      """
      Options for the `direction` argument of `@orderBy`.
      """
      enum OrderByDirection {
        """
        Sort in ascending order.
        """
        ASC

        """
        Sort in descending order.
        """
        DESC
      }
    GRAPHQL
    'OrderByRelation' => <<~GRAPHQL.chomp
      """
      Options for the `relations` argument of `@orderBy`.
      """
      input OrderByRelation {
        """
        Name of the relation.
        """
        relation: String!

        """
        Restrict the allowed column names to a well-defined list.
        This improves introspection capabilities and security.
        Mutually exclusive with `columnsEnum`.
        """
        columns: [String!]

        """
        Use an existing enumeration type to restrict the allowed columns to a predefined list.
        This allows you to re-use the same enum for multiple fields.
        Mutually exclusive with `columns`.
        """
        columnsEnum: String
      }
    GRAPHQL
  }.freeze

  def self.directive_name = 'orderBy'

  def self.definition = DEFINITION

  def self.type_definitions = TYPE_DEFINITIONS

  # --- Schema: the argument's types (Lighthouse::OrderBy::Types) ------------

  def manipulate_arg_definition(document_ast, field, type)
    Lighthouse::OrderBy::Types.new(document_ast, @directive_node, @arg_node, field, type).argument
  end

  # --- Runtime --------------------------------------------------------------

  def handle_builder(relation, value)
    Array(value).each_with_index.reduce(relation) { |ordered, (clause, index)| order_by(ordered, symbolized(clause), index) }
  end

  # On a field: `column:` in `direction:`.
  def handle_field_builder(relation)
    column = Lighthouse::Support::DirectiveArgs.literal(@directive_node, 'column')
    return relation unless column

    direction = Lighthouse::Support::DirectiveArgs.literal(@directive_node, 'direction').to_s.casecmp?('DESC') ? :desc : :asc
    relation.order(column_attribute(relation, column).public_send(direction))
  end

  private

  def relations
    @relations ||= Array(Lighthouse::Support::DirectiveArgs.literal(@directive_node, 'relations')).map { |relation| relation.transform_keys(&:to_s) }
  end

  def order_by(relation, clause, index)
    direction = clause[:order].to_s.casecmp?('DESC') ? :desc : :asc
    aggregated = clause.except(:column, :order).compact
    unless clause[:column].nil? ^ aggregated.empty?
      raise ::GraphQL::ExecutionError, "An order by clause takes exactly one of: column, #{relations.pluck('relation').join(', ')}."
    end
    return relation.order(column_attribute(relation, clause[:column]).public_send(direction)) if clause[:column]

    relation_name, aggregate = aggregated.first
    order_by_aggregate(relation, relation_name, symbolized(aggregate), direction, index)
  end

  # LEFT JOIN (SELECT owner.id, AGGREGATE(related.column) FROM owner LEFT JOIN related ... GROUP BY owner.id)
  # and ORDER BY the aggregate.
  def order_by_aggregate(relation, relation_name, aggregate, direction, index)
    owner = relation.klass
    reflection = reflection(owner, relation_name)
    key = owner.arel_table[owner.primary_key]
    table = ::Arel::Table.new("lighthouse_order_#{index}_#{reflection.name}")
    totals = owner.unscoped.left_joins(reflection.name).group(key)
                  .select(key.as('lighthouse_key'), aggregate_node(reflection.klass, aggregate).as('lighthouse_aggregate'))

    relation.joins(left_join(owner, totals, table, key)).order(table[:lighthouse_aggregate].public_send(direction))
  end

  def left_join(owner, totals, table, key)
    subquery = ::Arel::Nodes::TableAlias.new(::Arel::Nodes::Grouping.new(totals.arel), table.name)
    owner.arel_table.join(subquery, ::Arel::Nodes::OuterJoin).on(table[:lighthouse_key].eq(key)).join_sources
  end

  def aggregate_node(related, aggregate)
    function = aggregate[:aggregate].to_s.downcase
    ::Arel::Nodes.const_get(AGGREGATES.fetch(function)).new([aggregated_attribute(related, function, aggregate[:column])])
  end

  # COUNT counts the related records (their primary key); the other aggregates need a column.
  def aggregated_attribute(related, function, column)
    return column_attribute(related.all, column, as: function == 'count' ? :sort : :numeric) if column
    raise ::GraphQL::ExecutionError, "Ordering by the #{function.upcase} of a relation needs a column." unless function == 'count'

    related.arel_table[related.primary_key]
  end

  def reflection(owner, name)
    candidates = [name.to_s, name.to_s.camelize(:lower), name.to_s.underscore].uniq
    configured = relations.pluck('relation')
    found = candidates.find { |candidate| configured.include?(candidate) } || name.to_s
    owner.reflect_on_association(found.to_sym) || owner.reflect_on_association(found.underscore.to_sym) ||
      raise(Lighthouse::DefinitionError, "@orderBy(relations:): #{owner.name} has no relation #{found}")
  end

  # A JSON path orders by its JSON value; an aggregate takes it as a number.
  def column_attribute(relation, column, as: :sort)
    Lighthouse::WhereConditions::Columns.attribute(relation.klass, column, as: as)
  end

  def symbolized(value)
    hash = value.respond_to?(:to_h) ? value.to_h : value
    hash.is_a?(Hash) ? hash.transform_keys { |key| key.to_s.underscore.to_sym } : {}
  end
end
