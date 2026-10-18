# frozen_string_literal: true

# Applies a @whereConditions value to a relation, as PHP Lighthouse's
# WhereConditionsHandler: the conditions of one level all hold, an AND list is
# a nested group whose conditions all hold, an OR list one where at least one
# does, and HAS checks how many related records match a condition.
#
#   { column: AGE, operator: GT, value: 37, OR: [{ column: TYPE, value: "Actor" }, ...] }
#   -> age > 37 AND (type = 'Actor' OR ...)
#
#   { HAS: { relation: "posts", amount: 3, condition: { column: "published", value: true } } }
#   -> users with at least 3 published posts
#
# A column the client names (an unrestricted WhereConditions takes any) must
# be an identifier, `table.column` at most (Columns). The columns of a HAS
# condition are those of the related model's table.
#
# A custom handler (`@whereConditions(handler: "...")`) is any object or
# class answering `call(relation, conditions)` with the relation.
module Lighthouse::WhereConditions::Handler
  Types = Lighthouse::WhereConditions::Types

  # How a HAS operator compares the number of related records with `amount`.
  COUNT_COMPARISONS = { 'EQ' => :eq, 'NEQ' => :not_eq, 'GT' => :gt, 'GTE' => :gteq, 'LT' => :lt, 'LTE' => :lteq }.freeze
  RUBY_COMPARISONS = { 'EQ' => :==, 'NEQ' => :!=, 'GT' => :>, 'GTE' => :>=, 'LT' => :<, 'LTE' => :<= }.freeze

  # The Arel predicate of each operator that takes a value: [method, how the value is passed].
  PREDICATES = {
    'LIKE' => [:matches, :pattern], 'NOT_LIKE' => [:does_not_match, :pattern],
    'IN' => [:in, :list], 'NOT_IN' => [:not_in, :list],
    'BETWEEN' => [:between, :range], 'NOT_BETWEEN' => [:not_between, :range]
  }.merge(COUNT_COMPARISONS.transform_values { |method| [method, :value] }).freeze

  module_function

  def call(relation, conditions)
    predicate = predicate(relation.klass, normalize(conditions))
    predicate ? relation.where(predicate) : relation
  end

  # The conditions as a Hash of :column, :operator, :value, :and, :or, :has
  # (and :relation, :amount, :condition in a HAS), leaving the value as given.
  def normalize(conditions)
    return nil if conditions.nil?

    hash = conditions.respond_to?(:to_h) ? conditions.to_h : conditions
    hash.each_with_object({}) do |(key, value), normalized|
      key = key.to_s.underscore.to_sym
      normalized[key] =
        case key
        when :and, :or then Array(value).map { |condition| normalize(condition) }
        when :has, :condition then normalize(value)
        else value
        end
    end
  end

  # The Arel predicate of one level of conditions, or nil when it has none.
  def predicate(klass, conditions)
    return nil if conditions.blank?

    nodes = [
      group(klass, conditions[:and], :and),
      group(klass, conditions[:or], :or),
      conditions[:has] && has(klass, conditions[:has]),
      conditions[:column] && column_condition(klass, conditions)
    ].compact
    nodes.empty? ? nil : nodes.reduce { |left, right| left.and(right) }
  end

  def group(klass, conditions, boolean)
    nodes = Array(conditions).filter_map { |condition| predicate(klass, condition) }
    return nil if nodes.empty?

    boolean == :and ? ::Arel::Nodes::Grouping.new(::Arel::Nodes::And.new(nodes)) : nodes.reduce { |left, right| left.or(right) }
  end

  def column_condition(klass, conditions)
    operator = (conditions[:operator] || Types::DEFAULT_OPERATOR).to_s.upcase
    compared_as = Lighthouse::WhereConditions::JsonColumn.compared_as(operator, conditions[:value])
    attribute = Lighthouse::WhereConditions::Columns.attribute(klass, conditions[:column], as: compared_as)
    return attribute.eq(nil) if operator == 'IS_NULL'
    return attribute.not_eq(nil) if operator == 'IS_NOT_NULL'

    unless conditions.key?(:value)
      raise ::GraphQL::ExecutionError, "Did not receive a value to match the WhereConditions for column #{conditions[:column]}."
    end

    compare(attribute, operator, conditions[:value])
  end

  def compare(attribute, operator, value)
    method, kind = PREDICATES[operator]
    raise ::GraphQL::ExecutionError, "Unknown SQLOperator #{operator}." unless method

    case kind
    when :pattern then attribute.public_send(method, value, nil, true) # LIKE, case-sensitive as SQL's
    when :list then attribute.public_send(method, Array(value))
    when :range then attribute.public_send(method, range(value))
    else attribute.public_send(method, value)
    end
  end

  def range(value)
    values = Array(value)
    raise ::GraphQL::ExecutionError, 'BETWEEN needs a value of two elements: [from, to].' unless values.size == 2

    values.first..values.last
  end

  # Records of `klass` with `amount` (compared by `operator`) related records
  # matching the condition: an IN over the records that have them, and, when
  # having none satisfies the comparison, the records that have none too.
  def has(klass, has)
    reflection = reflection(klass, has[:relation])
    operator = (has[:operator] || Types::DEFAULT_HAS_OPERATOR).to_s.upcase
    amount = (has[:amount] || Types::DEFAULT_HAS_AMOUNT).to_i
    raise ::GraphQL::ExecutionError, "HAS can not compare the amount with #{operator}." unless COUNT_COMPARISONS.key?(operator)

    key = klass.arel_table[klass.primary_key]
    related = related_scope(klass, reflection, has[:condition])
    predicate = key.in(owners(related, key, reflection.klass, operator, amount).arel)
    0.public_send(RUBY_COMPARISONS.fetch(operator), amount) ? predicate.or(key.not_in(related.select(key).arel)) : predicate
  end

  # `klass` joined to its related records that match the condition.
  def related_scope(klass, reflection, condition)
    scope = klass.unscoped.joins(reflection.name)
    predicate = predicate(reflection.klass, condition)
    predicate ? scope.where(predicate) : scope
  end

  # The keys of the records with `amount` related records, by `operator`. At
  # least one is any join; another amount needs them counted.
  def owners(related_scope, key, related, operator, amount)
    return related_scope.select(key) if (operator == 'GTE' && amount == 1) || (operator == 'GT' && amount.zero?)

    counted = related.primary_key ? related.arel_table[related.primary_key] : ::Arel.star
    count = ::Arel::Nodes::Count.new([counted], true)
    related_scope.group(key).having(count.public_send(COUNT_COMPARISONS.fetch(operator), amount)).select(key)
  end

  # The association `name` names on `klass`: as written, snake_cased, singular or plural.
  def reflection(klass, name)
    candidates = [name.to_s, name.to_s.underscore, name.to_s.underscore.singularize, name.to_s.underscore.pluralize].uniq
    reflection = candidates.lazy.filter_map { |candidate| klass.reflect_on_association(candidate.to_sym) }.first
    raise ::GraphQL::ExecutionError, "#{klass.name} has no relation #{name}." unless reflection
    raise ::GraphQL::ExecutionError, "HAS can not check the polymorphic relation #{name}." if reflection.polymorphic?

    reflection
  end
end
