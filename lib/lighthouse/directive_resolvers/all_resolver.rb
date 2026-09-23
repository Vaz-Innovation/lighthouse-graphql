# frozen_string_literal: true

require_relative 'base'
require_relative 'builder_applier'

module Lighthouse
  module GraphQL
    module DirectiveResolvers
      class AllDirectiveResolver < BaseDirectiveResolver
        def define_resolver(target_type_class)
          field_name = @field_def.name

          resolver_instance = self
          field_ast_node = @field_def.ast_node

          method_name = "resolve_field_#{field_name}"

          model_name_static = extract_model_name || @field_def.type.unwrap.name
          model_class_static = constantize_model(model_name_static)

          target_type_class.define_singleton_method(method_name) do |_obj, arguments, ctx|
            model_class = model_class_static
            return [] unless model_class

            # apply simple pagination args if present
            args = arguments.respond_to?(:to_h) ? arguments.to_h : {}
            relation = model_class.all

            relation = DirectiveResolvers::BuilderApplier.apply(relation, field_ast_node, args, ctx, resolver_instance)

            relation = resolver_instance.apply_where_filters(relation, args)
            relation = relation.limit(args[:first]) if args[:first]
            relation = relation.offset(args[:offset]) if args[:offset]
            relation
          end

          if @field_def.respond_to?(:resolve_proc=)
            @field_def.resolve_proc = ->(_obj, arguments, ctx) do
              model_class = model_class_static
              if model_class.nil?
                []
              else
                args = arguments.respond_to?(:to_h) ? arguments.to_h : {}
                relation = model_class.all

                relation = DirectiveResolvers::BuilderApplier.apply(relation, field_ast_node, args, ctx, resolver_instance)

                relation = resolver_instance.apply_where_filters(relation, args)
                relation = relation.limit(args[:first]) if args[:first]
                relation = relation.offset(args[:offset]) if args[:offset]
                relation
              end
            end
          end
        end

        private

        def extract_model_name
          arg = @directive_node.arguments&.find { |a| a.name == 'model' }
          return nil unless arg
          arg.value.respond_to?(:value) ? arg.value.value : arg.value
        end

        def constantize_model(name)
          return nil unless name
          name = name.to_s.split('::').last
          Object.const_get(name) rescue nil
        end
      end
    end
  end
end
