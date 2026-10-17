# frozen_string_literal: true

require_relative 'base'

module Lighthouse
  module GraphQL
    module DirectiveResolvers
      class BelongsToDirectiveResolver < BaseDirectiveResolver
        def self.directive_name = 'belongsTo'
        def self.definition = 'directive @belongsTo(relation: String) on FIELD_DEFINITION'

        def define_resolver(target_type_class)
          field_name = @field_def.name
          assoc_name = extract_relation_name || field_name
          method_name = "resolve_field_#{field_name}"

          target_type_class.define_singleton_method(method_name) do |obj, _arguments, ctx|
            if ctx && ctx.respond_to?(:dataloader) && ctx.dataloader
              loader = ctx.dataloader.with(Lighthouse::GraphQL::DataloaderSources::AssociationLoader, obj.class, assoc_name)
              return loader.load(obj)
            end

            obj.public_send(assoc_name) if obj.respond_to?(assoc_name)
          end

          if @field_def.respond_to?(:resolve_proc=)
            @field_def.resolve_proc = ->(obj, _arguments, ctx) do
              if ctx && ctx.respond_to?(:dataloader) && ctx.dataloader
                loader = ctx.dataloader.with(Lighthouse::GraphQL::DataloaderSources::AssociationLoader, obj.class, assoc_name)
                loader.load(obj)
              elsif obj.respond_to?(assoc_name)
                obj.public_send(assoc_name)
              else
                nil
              end
            end
          end
        end

        private

        def extract_relation_name
          arg = @directive_node.arguments&.find { |a| a.name == 'relation' }
          return nil unless arg
          arg.value.respond_to?(:value) ? arg.value.value : arg.value
        end
      end
    end
  end
end
