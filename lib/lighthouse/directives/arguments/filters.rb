# frozen_string_literal: true

require_relative 'base'

module Lighthouse::GraphQL::Directives::Arguments
  # @eq — equality filter (the default). `field(status: String @eq)`
  class Eq < Base
    def self.directive_name = 'eq'
    def self.definition = sdl('eq', 'Add an equality filter to the query: the column equals the value.')

    def handle_builder(relation, value)
      return relation if value.nil?

      relation.where(column => value)
    end
  end

  # @whereKey — filter by the model's primary key, whatever its column is
  # named; a list matches any of its values. `deletePosts(ids: [ID!]! @whereKey)`
  class WhereKey < Base
    def self.directive_name = 'whereKey'
    def self.definition = sdl('whereKey', "Filter by the model's primary key, whatever its column is named. A list matches any of its values.", nil)

    def handle_builder(relation, value)
      return relation if value.nil?

      relation.where(relation.klass.primary_key => value)
    end
  end

  # @neq — inequality filter.
  class Neq < Base
    def self.directive_name = 'neq'
    def self.definition = sdl('neq', 'Add an inequality filter to the query: the column differs from the value.')

    def handle_builder(relation, value)
      return relation if value.nil?

      relation.where.not(column => value)
    end
  end

  # @in — value is one of a list.
  class In < Base
    def self.directive_name = 'in'
    def self.definition = sdl('in', 'Filter by a list of values: the column is one of them.')

    def handle_builder(relation, value)
      return relation if value.nil?

      relation.where(column => Array(value))
    end
  end

  # @notIn — value is none of a list.
  class NotIn < Base
    def self.directive_name = 'notIn'
    def self.definition = sdl('notIn', 'Filter by a list of values: the column is none of them.')

    def handle_builder(relation, value)
      return relation if value.nil?

      relation.where.not(column => Array(value))
    end
  end

  # @like — SQL LIKE with the value wrapped in wildcards.
  class Like < Base
    def self.directive_name = 'like'
    def self.definition = sdl('like', 'Filter with SQL LIKE: the column contains the value, which is wrapped in wildcards.')

    def handle_builder(relation, value)
      return relation if value.nil?

      relation.where(arel_column(relation).matches("%#{value}%"))
    end
  end

  # @where — generic operator filter, sharing the SQLOperator semantics with
  # the @whereConditions extension. `field(age: Int @where(operator: "GT"))`
  class Where < Base
    def self.directive_name = 'where'

    def self.definition
      sdl('where', 'Add a where condition to the query: the column compares to the value with an operator.',
          "#{KEY_ARGUMENT}\n#{OPERATOR_ARGUMENT}")
    end

    OPERATOR_ARGUMENT = argument_sdl(
      'operator: String',
      'The comparison: EQ (default), NEQ, GT, GTE, LT, LTE, IN, NIN, CONTAINS, STARTS_WITH, ENDS_WITH, IS_NULL or IS_NOT_NULL.'
    )

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
