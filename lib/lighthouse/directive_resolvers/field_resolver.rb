# frozen_string_literal: true

require_relative 'base'

module Lighthouse
  module GraphQL
    module DirectiveResolvers
      class FieldDirectiveResolver < BaseDirectiveResolver
        def define_resolver(target_type_class)
          field_name = @field_def.name
          method_name = "resolve_field_#{field_name}"

          resolver_class_name = extract_directive_arg('resolver') || extract_directive_arg('class')
          resolver_instance = self

          resolver = proc do |obj, args, ctx|
            begin
              resolver_class = resolver_instance.constantize_model(resolver_class_name)
              return nil unless resolver_class

              if resolver_class.respond_to?(:call)
                result = resolver_class.call(obj, args, ctx)
              else
                instance = resolver_class.new
                if instance.respond_to?(:call)
                  result = instance.call(obj, args, ctx)
                elsif instance.respond_to?(:resolve)
                  result = instance.resolve(obj, args, ctx)
                else
                  result = nil
                end
              end

              result
            rescue StandardError => e
              raise e
            end
          end

          target_type_class.define_singleton_method(method_name, &resolver)

          if @field_def.respond_to?(:resolve_proc=)
            @field_def.resolve_proc = resolver
          end
        end

        private

        def extract_directive_arg(name)
          arg = @directive_node.arguments&.find { |a| a.name == name }
          return nil unless arg
          arg.value.respond_to?(:value) ? arg.value.value : arg.value
        end

        def execute_resolver(resolver_class, obj, args, ctx)
          return nil unless resolver_class

          if resolver_class.respond_to?(:call)
            resolver_class.call(obj, args, ctx)
          elsif resolver_class.respond_to?(:new)
            instance = resolver_class.new
            if instance.respond_to?(:call)
              instance.call(obj, args, ctx)
            elsif instance.respond_to?(:resolve)
              instance.resolve(obj, args, ctx)
            else
              nil
            end
          else
            nil
          end
        rescue StandardError => e
          raise e
        end
      end
    end
  end
end
