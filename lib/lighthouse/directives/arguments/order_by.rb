# frozen_string_literal: true

require_relative 'base'

module Lighthouse
  module GraphQL
    module Directives
      module Arguments
        # @orderBy — sort the result by one or more columns.
        #
        # The client value is a list of clauses, each `{ column:, order: }`
        # (also accepts `{ field:, direction: }`). Clauses apply in order, so
        # `[{column: NAME, order: ASC}, {column: AGE, order: DESC}]` sorts by
        # name then age.
        class OrderBy < Base
          def self.directive_name = 'orderBy'
          def self.definition = 'directive @orderBy(columns: [String!], relations: [String!]) on ARGUMENT_DEFINITION | FIELD_DEFINITION'

          def handle_builder(relation, value)
            normalize(value).reduce(relation) do |rel, clause|
              col = Lighthouse::Support::Naming.column(clause[:column], rel)
              next rel if col.nil? || col.empty?

              direction = clause[:order].to_s.downcase == 'desc' ? :desc : :asc
              rel.order(col => direction)
            end
          end

          private

          def normalize(value)
            list = value.is_a?(Array) ? value : [value]
            list.filter_map do |item|
              hash = item.respond_to?(:to_h) ? item.to_h : item
              next nil unless hash.is_a?(Hash)

              symbolized = hash.transform_keys { |k| k.to_s.to_sym }
              col = symbolized[:column] || symbolized[:field]
              next nil if col.nil?

              { column: col, order: symbolized[:order] || symbolized[:direction] || 'ASC' }
            end
          end
        end
      end
    end
  end
end
