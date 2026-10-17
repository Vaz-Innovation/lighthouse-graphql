# frozen_string_literal: true

require_relative 'base'

module Lighthouse
  module GraphQL
    module DirectiveResolvers
      class BuilderApplier
        DEFINITION = 'directive @builder(class: String!, method: String) repeatable on FIELD_DEFINITION'

        def self.apply(relation, field_def_ast_node, args, ctx, resolver_instance)
          return relation unless field_def_ast_node && field_def_ast_node.directives

          builder_directives = field_def_ast_node.directives.select { |d| d.name == 'builder' }
          return relation if builder_directives.empty?

          builder_directives.each do |directive_node|
            relation = apply_directive(relation, directive_node, args, ctx, resolver_instance)
          end

          relation
        end

        def self.apply_directive(relation, directive_node, args, ctx, resolver_instance)
          class_name = extract_directive_arg(directive_node, 'class')
          method_name = extract_directive_arg(directive_node, 'method') || 'call'

          return relation unless class_name

          builder_class = resolver_instance.send(:constantize_model, class_name)
          return relation unless builder_class

          if builder_class.respond_to?(method_name)
            result = builder_class.public_send(method_name, relation, args, ctx)
            result || relation
          elsif builder_class.is_a?(Class)
            instance = builder_class.new
            if instance.respond_to?(method_name)
              result = instance.public_send(method_name, relation, args, ctx)
              result || relation
            else
              relation
            end
          else
            relation
          end
        rescue ::GraphQL::ExecutionError
          # Client-facing errors (e.g. authorization / scoping guards raised by a
          # builder) MUST propagate — never silently fall back to the unscoped
          # relation, or a builder that enforces tenancy could be bypassed.
          raise
        rescue StandardError => e
          Lighthouse::Config.handle_error(e)
          relation
        end

        def self.extract_directive_arg(directive_node, name)
          arg = directive_node.arguments&.find { |a| a.name == name }
          return nil unless arg
          arg.value.respond_to?(:value) ? arg.value.value : arg.value
        end
      end
    end
  end
end
