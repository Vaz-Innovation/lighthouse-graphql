# frozen_string_literal: true

class Lighthouse::GraphQL::DirectiveResolvers::WhereConditionsApplier
  # Operator semantics live in Lighthouse::WhereConditions::OperatorMap so
  # they can be shared with the simple argument-filter directives.
  SUPPORTED_OPERATORS = Lighthouse::WhereConditions::OperatorMap::OPERATORS
  # graphql-ruby hands input objects over with Ruby-style keys, so the
  # generated input's AND/OR/HAS fields arrive as :and/:or/:has.
  LOGICAL_KEYS = { and: :AND, or: :OR, has: :HAS }.freeze

  class << self
    def apply(relation, value)
      return relation unless relation.respond_to?(:where)

      condition = normalize_condition(value)
      return relation unless condition

      # AND narrows the incoming scope step by step; each OR branch starts
      # from the incoming scope, and their union replaces it.
      result = apply_all(relation, condition[:AND])
      result = apply_any(relation, condition[:OR]) || result
      result = apply_has_condition(result, condition[:HAS])
      result = apply_single_condition(result, condition) if condition.key?(:column)
      result
    end

    def apply_has(relation, has_cond)
      relation_name = has_cond[:relation].to_s
      return relation if relation_name.blank?

      resolved_relation_name = resolve_relation_name(relation, relation_name)
      return relation if resolved_relation_name.blank?

      reflection = reflection_for(relation, resolved_relation_name)
      return relation unless reflection&.klass

      joined = relation.joins(resolved_relation_name.to_sym)
      return joined.distinct if has_cond[:condition].blank?

      # Use an EXISTS-style filter to safely apply conditions from the related model.
      child_scope = apply(reflection.klass.all, has_cond[:condition])
      joined.where(reflection.klass.table_name => { id: child_scope.select(:id) }).distinct
    rescue StandardError
      relation
    end

    def resolve_relation_name(relation, relation_name)
      candidate_names = [relation_name.to_s, relation_name.to_s.singularize, relation_name.to_s.pluralize].uniq

      candidate_names.each do |candidate|
        next if candidate.blank?
        return candidate if association_exists?(relation, candidate)
      end

      nil
    rescue StandardError
      nil
    end

    def association_exists?(relation, name)
      reflection_for(relation, name).present?
    rescue StandardError
      false
    end

    def apply_has_argument(relation, arg_name, arg_value, relation_name = nil)
      relation_name ||= derive_relation_name(arg_name)
      return relation unless relation_name.present? && arg_value.present?

      condition = arg_value.is_a?(Hash) ? arg_value : symbolized(arg_value)
      has_payload = { relation: relation_name, condition: condition }
      apply_has(relation, has_payload)
    end

    private

    # The condition as a symbol-keyed Hash, or nil when there is none.
    def normalize_condition(value)
      return nil if value.nil?

      condition = value.is_a?(Hash) ? value.deep_symbolize_keys : symbolized(value)
      condition.transform_keys { |key| LOGICAL_KEYS.fetch(key, key) } if condition.is_a?(Hash)
    end

    def apply_all(relation, conditions)
      Array(conditions).reduce(relation) { |acc, sub| apply(acc, sub) }
    end

    # The union of the branches, or nil when there are none.
    def apply_any(relation, conditions)
      Array(conditions).map { |sub| apply(relation, sub) }.reduce { |acc, sub_scope| acc.or(sub_scope) }
    end

    def apply_has_condition(relation, has_cond)
      return relation unless has_cond.is_a?(Hash) && has_cond[:relation]

      apply_has(relation, has_cond)
    end

    def reflection_for(relation, name)
      klass = relation.respond_to?(:klass) ? relation.klass : relation
      klass.reflect_on_association(name.to_sym) if klass.respond_to?(:reflect_on_association)
    end

    def derive_relation_name(arg_name)
      Lighthouse::Support::Naming.derive_relation_name(arg_name)
    end

    def apply_single_condition(relation, condition)
      return relation if condition[:column].blank? || !relation.respond_to?(:where)

      column_name = resolve_column_name(condition[:column])
      return relation if column_name.blank?

      apply_operator(relation, column_name, operator_of(condition), condition[:value])
    rescue StandardError
      relation
    end

    def operator_of(condition)
      condition[:operator]&.to_s&.upcase || 'EQ'
    end

    # Null and set operators are plain hash conditions; the rest need Arel.
    def apply_operator(relation, column_name, operator, value)
      case operator
      when 'IS_NULL' then relation.where(column_name => nil)
      when 'IS_NOT_NULL' then relation.where.not(column_name => nil)
      when 'IN' then relation.where(column_name => Array(value))
      when 'NIN' then relation.where.not(column_name => Array(value))
      else apply_arel_operator(relation, column_name, operator, value)
      end
    end

    # An unknown operator falls back to equality rather than failing the query.
    def apply_arel_operator(relation, column_name, operator, value)
      pattern = like_pattern(operator, value)
      return relation.where(arel_table(relation)[column_name].matches(pattern)) if pattern

      predicate = SUPPORTED_OPERATORS[operator]
      return relation.where(column_name => value) unless predicate

      relation.where(arel_table(relation)[column_name].public_send(predicate, value))
    end

    def like_pattern(operator, value)
      case operator
      when 'CONTAINS' then "%#{value}%"
      when 'STARTS_WITH' then "#{value}%"
      when 'ENDS_WITH' then "%#{value}"
      end
    end

    def resolve_column_name(column)
      Lighthouse::Support::Naming.column(column)
    end

    def arel_table(relation)
      relation.klass.arel_table
    end

    def symbolized(obj)
      if obj.respond_to?(:to_h)
        obj.to_h.deep_symbolize_keys
      else
        {}
      end
    end
  end
end
