# frozen_string_literal: true

require_relative 'base'

module Lighthouse
  module GraphQL
    module DirectiveResolvers
      # @guard — require an authenticated user before the field resolves.
      # Wraps the field's resolver; raises "Unauthenticated." when no user is
      # present (per Config.authenticated_user). Mirrors PHP Lighthouse's @guard.
      class GuardDirectiveResolver < BaseDirectiveResolver
        def self.directive_name = 'guard'
        def self.definition = 'directive @guard on FIELD_DEFINITION'

        def define_resolver(target_type_class)
          field_name = @field_def.name
          method_name = "resolve_field_#{field_name}"
          inner = Resolution.capture(target_type_class, method_name, @field_def, field_name)

          wrapper = lambda do |obj, arguments, ctx|
            raise(::GraphQL::ExecutionError, 'Unauthenticated.') unless Lighthouse::Support::Authorization.authenticated?(ctx)

            inner.call(obj, arguments, ctx)
          end

          target_type_class.define_singleton_method(method_name, &wrapper)
          @field_def.resolve_proc = wrapper if @field_def.respond_to?(:resolve_proc=)
        end
      end
    end
  end
end
