# frozen_string_literal: true

# Maps the GraphQL SQLOperator enum values to Arel predicate methods.
# Extracted from WhereConditionsApplier so that simple argument-filter
# directives (@eq, @neq, @in, @notIn, @like, @where) can share the same
# operator semantics.
module Lighthouse::WhereConditions::OperatorMap
  OPERATORS = {
    'EQ' => :eq,
    'NEQ' => :not_eq,
    'GT' => :gt,
    'GTE' => :gteq,
    'LT' => :lt,
    'LTE' => :lteq,
    'IN' => :in,
    'NIN' => :not_in,
    'CONTAINS' => :matches,
    'STARTS_WITH' => :matches,
    'ENDS_WITH' => :matches,
    'IS_NULL' => :eq,
    'IS_NOT_NULL' => :not_eq
  }.freeze

  def self.[](operator)
    OPERATORS[operator]
  end

  def self.supported?(operator)
    OPERATORS.key?(operator)
  end
end
