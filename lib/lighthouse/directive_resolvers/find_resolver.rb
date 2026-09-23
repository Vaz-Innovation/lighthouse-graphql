# frozen_string_literal: true

require_relative 'base'

module Lighthouse
  module GraphQL
    module DirectiveResolvers
      class FindDirectiveResolver < BaseDirectiveResolver
        def define_resolver(target_type_class)
          field_name = @field_def.name
          method_name = "resolve_field_#{field_name}"

          model_name_static = extract_model_name || @field_def.type.unwrap.name
          model_class_static = constantize_model(model_name_static)

          target_type_class.define_singleton_method(method_name) do |_obj, arguments, ctx|
            args = arguments.respond_to?(:to_h) ? arguments.to_h : {}
            id = args[:id] || args['id']

            model_class = model_class_static
            return nil unless model_class

            if id && ctx&.dataloader
              loader = ctx.dataloader.with(Lighthouse::GraphQL::DataloaderSources::ModelLoader, model_class)
              return loader.load(id)
            end

            model_class.find_by(id: id)
          end

          if @field_def.respond_to?(:resolve_proc=)
            @field_def.resolve_proc = ->(_obj, arguments, ctx) do
              args = arguments.respond_to?(:to_h) ? arguments.to_h : {}
              id = args[:id] || args['id']

              model_class = model_class_static
              if model_class.nil?
                nil
              elsif id && ctx&.dataloader
                loader = ctx.dataloader.with(Lighthouse::GraphQL::DataloaderSources::ModelLoader, model_class)
                loader.load(id)
              else
                model_class.find_by(id: id)
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
