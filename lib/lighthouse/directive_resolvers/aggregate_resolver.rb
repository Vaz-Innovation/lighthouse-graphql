# frozen_string_literal: true

require_relative 'base'
require_relative 'builder_applier'

module Lighthouse
  module GraphQL
    module DirectiveResolvers
      class AggregateDirectiveResolver < BaseDirectiveResolver
        def define_resolver(target_type_class)
          field_name = @field_def.name
          method_name = "resolve_field_#{field_name}"

          model_name = extract_directive_arg('model')
          relation_name = extract_directive_arg('relation')
          column_name = extract_directive_arg('column')
          function_name = extract_directive_arg('function')
          resolver_instance = self
          field_ast_node = @field_def.ast_node

          resolver_lambda = lambda do |obj, args, ctx|
            relation = if model_name
              model_class = resolver_instance.send(:constantize_model, model_name)
              model_class ? model_class.all : nil
            elsif relation_name && obj.respond_to?(relation_name)
              obj.public_send(relation_name)
            else
              nil
            end

            return nil unless relation

            relation = DirectiveResolvers::BuilderApplier.apply(relation, field_ast_node, args, ctx, resolver_instance)
            resolver_instance.send(:compute_aggregation, relation, column_name, function_name)
          end

          target_type_class.define_singleton_method(method_name, &resolver_lambda)
          @field_def.resolve_proc = resolver_lambda if @field_def.respond_to?(:resolve_proc=)
        end

        private

        def extract_directive_arg(name)
          arg = @directive_node.arguments&.find { |a| a.name == name }
          return nil unless arg
          v = arg.value.respond_to?(:value) ? arg.value.value : arg.value
          v.is_a?(::GraphQL::Language::Nodes::Enum) ? v.name : v
        end

        def compute_aggregation(relation, column, function_name)
          return nil unless relation.respond_to?(:any?)
          column = column.to_s
          case function_name.to_s.upcase
          when 'SUM'
            relation.sum(column)
          when 'AVG'
            relation.average(column)&.to_f
          when 'MIN'
            relation.minimum(column)
          when 'MAX'
            relation.maximum(column)
          when 'COUNT'
            relation.count
          else
            nil
          end
        rescue StandardError
          nil
        end

        def set_resolve_proc(method_name)
          if @field_def.respond_to?(:resolve_proc=)
            @field_def.resolve_proc = ->(obj, arguments, ctx) do
              target_type_class = self.class
              if target_type_class.respond_to?(method_name)
                target_type_class.public_send(method_name, obj, arguments, ctx)
              else
                nil
              end
            end
          end
        end
      end
    end
  end
end
