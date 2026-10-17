# frozen_string_literal: true

module Lighthouse
  module GraphQL
    module DirectiveResolvers
      class AuthDirectiveResolver < BaseDirectiveResolver
        def self.directive_name = 'auth'
        def self.definition = 'directive @auth on FIELD_DEFINITION'

        def define_resolver(target_type_class)
          field_name = @field_def.name
          method_name = "resolve_field_#{field_name}"

          original_singleton =
            if target_type_class.respond_to?(method_name)
              target_type_class.method(method_name)
            end

          original_proc =
            if @field_def.respond_to?(:resolve_proc)
              @field_def.resolve_proc
            end

          wrapper = lambda do |obj, arguments, ctx|
            user = ctx && (ctx[:current_user] || ctx['current_user'])
            raise(::GraphQL::ExecutionError, 'Unauthenticated.') unless user

            if original_singleton
              original_singleton.call(obj, arguments, ctx)
            elsif original_proc
              original_proc.call(obj, arguments, ctx)
            elsif obj.respond_to?(field_name)
              obj.public_send(field_name)
            else
              snake = field_name.to_s.underscore
              obj.respond_to?(snake) ? obj.public_send(snake) : nil
            end
          end

          target_type_class.define_singleton_method(method_name, &wrapper)
          @field_def.resolve_proc = wrapper if @field_def.respond_to?(:resolve_proc=)
        end
      end
    end
  end
end

