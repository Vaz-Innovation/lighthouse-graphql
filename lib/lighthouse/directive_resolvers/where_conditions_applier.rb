# frozen_string_literal: true

module Lighthouse
  module GraphQL
    module DirectiveResolvers
      class WhereConditionsApplier
        # Operator semantics live in Lighthouse::WhereConditions::OperatorMap so
        # they can be shared with the simple argument-filter directives.
        SUPPORTED_OPERATORS = Lighthouse::WhereConditions::OperatorMap::OPERATORS

        class << self
          def apply(relation, value)
            return relation unless relation.respond_to?(:where)
            return relation if value.nil?

            condition = value.is_a?(Hash) ? value.deep_symbolize_keys : symbolized(value)
            return relation unless condition.is_a?(Hash)

            result = relation

            if condition.key?(:AND)
              Array(condition[:AND]).each do |sub|
                result = apply(result, sub)
              end
            end

            if condition.key?(:OR)
              or_rel = nil
              Array(condition[:OR]).each do |sub|
                sub_scope = apply(relation, sub)
                or_rel = or_rel ? or_rel.or(sub_scope) : sub_scope
              end
              result = or_rel if or_rel
            end

            if condition.key?(:HAS)
              has_cond = condition[:HAS]
              if has_cond.is_a?(Hash) && has_cond[:relation]
                result = apply_has(result, has_cond)
              end
            end

            if condition.key?(:column)
              result = apply_single_condition(result, condition)
            end

            result
          end

          def apply_has(relation, has_cond)
            relation_name = has_cond[:relation].to_s
            return relation unless relation_name.present?

            resolved_relation_name = resolve_relation_name(relation, relation_name)
            return relation unless resolved_relation_name.present?

            source_klass = relation.respond_to?(:klass) ? relation.klass : relation
            reflection = source_klass.respond_to?(:reflect_on_association) ? source_klass.reflect_on_association(resolved_relation_name.to_sym) : nil
            return relation unless reflection&.klass

            if has_cond[:condition].present?
              child_scope = reflection.klass.all
              child_scope = apply(child_scope, has_cond[:condition])

              # Use an EXISTS-style filter to safely apply conditions from the related model.
              table_name = reflection.klass.table_name
              relation.joins(resolved_relation_name.to_sym)
                      .where(table_name => { id: child_scope.select(:id) })
                      .distinct
            else
              relation.joins(resolved_relation_name.to_sym).distinct
            end
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
            klass = relation.respond_to?(:klass) ? relation.klass : relation
            return false unless klass.respond_to?(:reflect_on_association)

            klass.reflect_on_association(name.to_sym).present?
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

          def derive_relation_name(arg_name)
            Lighthouse::Support::Naming.derive_relation_name(arg_name)
          end

          def apply_single_condition(relation, condition)
            col = condition[:column]
            op = condition[:operator]&.to_s&.upcase || 'EQ'
            value = condition[:value]

            return relation if col.blank? || !relation.respond_to?(:where)

            column_name = resolve_column_name(col)
            return relation if column_name.blank?

            case op
            when 'IS_NULL'
              relation.where(column_name => nil)
            when 'IS_NOT_NULL'
              relation.where.not(column_name => nil)
            when 'IN'
              relation.where(column_name => Array(value))
            when 'NIN'
              relation.where.not(column_name => Array(value))
            when 'CONTAINS'
              relation.where(arel_table(relation)[column_name].matches("%#{value}%"))
            when 'STARTS_WITH'
              relation.where(arel_table(relation)[column_name].matches("#{value}%"))
            when 'ENDS_WITH'
              relation.where(arel_table(relation)[column_name].matches("%#{value}"))
            else
              if SUPPORTED_OPERATORS[op]
                relation.where(arel_table(relation)[column_name].public_send(SUPPORTED_OPERATORS[op], value))
              else
                relation.where(column_name => value)
              end
            end
          rescue StandardError
            relation
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
    end
  end
end
