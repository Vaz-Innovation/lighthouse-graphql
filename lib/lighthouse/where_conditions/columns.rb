# frozen_string_literal: true

# The column a client names in @whereConditions or @orderBy, as an Arel node.
# Enum values (`CREATED_AT`, or the column an @enum(value:) gives) map onto
# columns as everywhere (Support::Naming). A column of an unrestricted input
# (`column: String`) comes from the client as is, so it must be an identifier,
# `table.column`, or either with a path into a JSON document (`meta->tags`,
# JsonColumn), as PHP Lighthouse checks it.
module Lighthouse::WhereConditions::Columns
  IDENTIFIER = /\A[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)?\z/

  module_function

  # The column on `klass`'s table, or `table.column`. A JSON path's value is
  # compiled `as` JsonColumn.node says: :sort to order by, :text, :numeric or
  # :boolean to compare with.
  def attribute(klass, column, as: :sort)
    json = Lighthouse::WhereConditions::JsonColumn
    if json.json?(column)
      raise ::GraphQL::ExecutionError, invalid_column_name(column) unless json.valid?(column)

      return json.node(klass, column, as: as)
    end

    name = Lighthouse::Support::Naming.column(column)
    raise ::GraphQL::ExecutionError, invalid_column_name(column) unless IDENTIFIER.match?(name)

    table, name = name.split('.', 2) if name.include?('.')
    table ? ::Arel::Table.new(table)[name] : klass.arel_table[name]
  end

  def invalid_column_name(column)
    'Column names may contain only alphanumerics or underscores, optionally a table and a JSON path ' \
      "(posts.meta->tags), and may not begin with a digit, got: #{column}"
  end
end
