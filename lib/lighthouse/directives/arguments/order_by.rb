# frozen_string_literal: true

require_relative 'base'

# @orderBy — sort the result by one or more columns.
#
# The client value is a list of clauses, each `{ column:, order: }`
# (also accepts `{ field:, direction: }`). Clauses apply in order, so
# `[{column: NAME, order: ASC}, {column: AGE, order: DESC}]` sorts by
# name then age.
class Lighthouse::GraphQL::Directives::Arguments::OrderBy < Lighthouse::GraphQL::Directives::Arguments::Base
  def self.directive_name = 'orderBy'
  def self.definition = 'directive @orderBy(columns: [String!], relations: [String!]) on ARGUMENT_DEFINITION | FIELD_DEFINITION'

  def handle_builder(relation, value)
    normalize(value).reduce(relation) do |rel, clause|
      col = Lighthouse::Support::Naming.column(clause[:column], rel)
      next rel if col.blank?

      direction = clause[:order].to_s.downcase == 'desc' ? :desc : :asc
      rel.order(col => direction)
    end
  end

  private

  def normalize(value)
    list = value.is_a?(Array) ? value : [value]
    list.filter_map { |item| clause(item) }
  end

  # One `{ column:, order: }` clause, or nil when the item names no column.
  def clause(item)
    symbolized = symbolized_hash(item)
    return nil unless symbolized

    col = symbolized[:column] || symbolized[:field]
    return nil if col.nil?

    { column: col, order: symbolized[:order] || symbolized[:direction] || 'ASC' }
  end

  # The item as a symbol-keyed hash, or nil when it is not hash-like.
  def symbolized_hash(item)
    hash = item.respond_to?(:to_h) ? item.to_h : item
    hash.transform_keys { |k| k.to_s.to_sym } if hash.is_a?(Hash)
  end
end
