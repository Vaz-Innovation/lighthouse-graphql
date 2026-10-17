# frozen_string_literal: true

require_relative 'base'

module Lighthouse::GraphQL::Directives::Arguments
  # @eq — equality filter (the default). `field(status: String @eq)`
  class Eq < Base
    def self.directive_name = 'eq'
    def self.definition = 'directive @eq(key: String) on ARGUMENT_DEFINITION | INPUT_FIELD_DEFINITION'

    def handle_builder(relation, value)
      return relation if value.nil?

      relation.where(column => value)
    end
  end

  # @whereKey — filter by the model's primary key, whatever its column is
  # named; a list matches any of its values. `deletePosts(ids: [ID!]! @whereKey)`
  class WhereKey < Base
    def self.directive_name = 'whereKey'
    def self.definition = 'directive @whereKey on ARGUMENT_DEFINITION | INPUT_FIELD_DEFINITION'

    def handle_builder(relation, value)
      return relation if value.nil?

      relation.where(relation.klass.primary_key => value)
    end
  end

  # @neq — inequality filter.
  class Neq < Base
    def self.directive_name = 'neq'
    def self.definition = 'directive @neq(key: String) on ARGUMENT_DEFINITION | INPUT_FIELD_DEFINITION'

    def handle_builder(relation, value)
      return relation if value.nil?

      relation.where.not(column => value)
    end
  end

  # @in — value is one of a list.
  class In < Base
    def self.directive_name = 'in'
    def self.definition = 'directive @in(key: String) on ARGUMENT_DEFINITION | INPUT_FIELD_DEFINITION'

    def handle_builder(relation, value)
      return relation if value.nil?

      relation.where(column => Array(value))
    end
  end

  # @notIn — value is none of a list.
  class NotIn < Base
    def self.directive_name = 'notIn'
    def self.definition = 'directive @notIn(key: String) on ARGUMENT_DEFINITION | INPUT_FIELD_DEFINITION'

    def handle_builder(relation, value)
      return relation if value.nil?

      relation.where.not(column => Array(value))
    end
  end

  # @like — SQL LIKE with the value wrapped in wildcards.
  class Like < Base
    def self.directive_name = 'like'
    def self.definition = 'directive @like(key: String) on ARGUMENT_DEFINITION | INPUT_FIELD_DEFINITION'

    def handle_builder(relation, value)
      return relation if value.nil?

      relation.where(arel_column(relation).matches("%#{value}%"))
    end
  end

  # @where — generic operator filter, sharing the SQLOperator semantics with
  # the @whereConditions extension. `field(age: Int @where(operator: "GT"))`
  class Where < Base
    def self.directive_name = 'where'
    def self.definition = 'directive @where(key: String, operator: String) on ARGUMENT_DEFINITION | INPUT_FIELD_DEFINITION'

    # LIKE pattern of each wildcard operator, built from the client value.
    LIKE_PATTERNS = {
      'CONTAINS' => ->(value) { "%#{value}%" },
      'STARTS_WITH' => ->(value) { "#{value}%" },
      'ENDS_WITH' => ->(value) { "%#{value}" }
    }.freeze

    def handle_builder(relation, value)
      return relation if value.nil?

      operator = sql_operator
      case operator
      when 'IN' then relation.where(column => Array(value))
      when 'NIN' then relation.where.not(column => Array(value))
      when 'IS_NULL' then relation.where(column => nil)
      when 'IS_NOT_NULL' then relation.where.not(column => nil)
      when *LIKE_PATTERNS.keys then relation.where(arel_column(relation).matches(LIKE_PATTERNS[operator].call(value)))
      else compare(relation, operator, value)
      end
    end

    private

    def sql_operator
      (Lighthouse::Support::DirectiveArgs.literal(@directive_node, 'operator') || 'EQ').to_s.upcase
    end

    # Comparison operators map onto Arel predicates; an unknown one falls
    # back to equality.
    def compare(relation, operator, value)
      arel_method = Lighthouse::WhereConditions::OperatorMap[operator]
      return relation.where(column => value) unless arel_method

      relation.where(arel_column(relation).public_send(arel_method, value))
    end
  end
end
