# frozen_string_literal: true

require_relative 'base'

module Lighthouse
  module GraphQL
    module DirectiveResolvers
      # @can — authorize access to a field using a policy ability (Pundit by
      # default; configurable via Config.authorizer). Mirrors PHP Lighthouse's
      # @can* family. Repeatable.
      #
      #   contact(id: ID!): Contact @field(resolver: "...") @can(ability: "show")
      #
      # Modes:
      #   * default          — resolve the field, then authorize the resolved
      #                        record (skips nil; passes collections through —
      #                        use scoping for lists).
      #   * root: true       — authorize the parent object before resolving.
      #   * find / model     — look the model up by an argument and authorize it
      #                        before resolving.
      class CanDirectiveResolver < BaseDirectiveResolver
        def self.directive_name = 'can'
        def self.definition
          'directive @can(ability: String!, find: String, model: String, root: Boolean) repeatable on FIELD_DEFINITION'
        end

        def define_resolver(target_type_class)
          field_name = @field_def.name
          method_name = "resolve_field_#{field_name}"
          ability = directive_arg('ability')
          return if ability.nil?

          find_arg = directive_arg('find')
          model_name = directive_arg('model')
          root = directive_arg('root')
          inner = Resolution.capture(target_type_class, method_name, @field_def, field_name)
          resolver_instance = self

          wrapper = lambda do |obj, arguments, ctx|
            if root
              resolver_instance.send(:authorize_or_raise, ctx, obj, ability)
              next inner.call(obj, arguments, ctx)
            end

            if find_arg && model_name
              args_h = arguments.respond_to?(:to_h) ? arguments.to_h : {}
              id = Lighthouse::Support::Naming.fetch_arg(args_h, find_arg)
              model_class = resolver_instance.send(:constantize_model, model_name)
              record = model_class&.find_by(id: id)
              resolver_instance.send(:authorize_or_raise, ctx, record, ability)
              next inner.call(obj, arguments, ctx)
            end

            result = inner.call(obj, arguments, ctx)
            resolver_instance.send(:authorize_resolved, ctx, result, ability)
          end

          target_type_class.define_singleton_method(method_name, &wrapper)
          @field_def.resolve_proc = wrapper if @field_def.respond_to?(:resolve_proc=)
        end

        private

        def directive_arg(name)
          Lighthouse::Support::DirectiveArgs.literal(@directive_node, name)
        end

        def authorize_resolved(ctx, result, ability)
          return result if result.nil?
          # Collections are filtered with scoping, not item-by-item authorization.
          return result if result.respond_to?(:each) && !result.respond_to?(:id)

          authorize_or_raise(ctx, result, ability)
          result
        end

        def authorize_or_raise(ctx, record, ability)
          return if record.nil?

          authorized = Lighthouse::Support::Authorization.authorized?(ctx, record, ability)
          raise(::GraphQL::ExecutionError, 'You are not authorized to perform this action.') unless authorized
        end
      end
    end
  end
end
