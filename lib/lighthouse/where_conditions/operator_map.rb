# frozen_string_literal: true

# Maps the operators @where(operator:) takes to Arel predicate methods.
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
