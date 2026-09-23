# frozen_string_literal: true

require_relative 'base'
require_relative 'builder_applier'

module Lighthouse
  module GraphQL
    module DirectiveResolvers
      # @count(model: "Model", relation: "assoc") — return the number of records.
      # Counts `Model.all` when `model:` is given, otherwise the named relation on
      # the parent object (or a relation matching the field name). Honors @builder
      # and where/argument filters before counting.
      class CountDirectiveResolver < BaseDirectiveResolver
        def self.directive_name = 'count'
        def self.definition = 'directive @count(model: String, relation: String, scopes: [String!]) on FIELD_DEFINITION'

        def define_resolver(target_type_class)
          field_name = @field_def.name
          method_name = "resolve_field_#{field_name}"
          model_name = directive_arg('model')
          relation_name = directive_arg('relation')
          resolver_instance = self
          field_ast_node = @field_def.ast_node

          resolver = lambda do |obj, arguments, ctx|
            args_h = arguments.respond_to?(:to_h) ? arguments.to_h : {}
            relation =
              if model_name
                model_class = resolver_instance.constantize_model(model_name)
                model_class&.all
              elsif relation_name && obj.respond_to?(relation_name)
                obj.public_send(relation_name)
              elsif obj.respond_to?(field_name)
                obj.public_send(field_name)
              end

            next 0 unless relation.respond_to?(:count)

            relation = DirectiveResolvers::BuilderApplier.apply(relation, field_ast_node, args_h, ctx, resolver_instance)
            relation = resolver_instance.apply_where_filters(relation, args_h)
            relation.count
          end

          target_type_class.define_singleton_method(method_name, &resolver)
          @field_def.resolve_proc = resolver if @field_def.respond_to?(:resolve_proc=)
        end

        private

        def directive_arg(name)
          Lighthouse::Support::DirectiveArgs.literal(@directive_node, name)
        end
      end
    end
  end
end
