# frozen_string_literal: true

module Lighthouse
  module GraphQL
    module DirectiveResolvers
      class BaseDirectiveResolver
        def initialize(field_def, type_def, directive_node, opts = {})
          @field_def = field_def
          @type_def = type_def
          @directive_node = directive_node
          @opts = opts
        end

        def define_resolver(target_type_class)
          raise NotImplementedError
        end

        def apply_where_filters(relation, args)
          return relation unless relation.respond_to?(:where)

          args_h = args.respond_to?(:to_h) ? args.to_h : (args || {})

          where_condition = args_h[:where] || args_h['where']
          relation = DirectiveResolvers::WhereConditionsApplier.apply(relation, where_condition) if where_condition

          @field_def.ast_node.arguments.each do |arg_node|
            next unless arg_node.directives.any? { |dir| dir.name == 'whereHasConditions' }

            arg_value = Lighthouse::Support::Naming.fetch_arg(args_h, arg_node.name)
            next unless arg_value

            relation_name = extract_relation_name_from_directive(arg_node) || Lighthouse::Support::Naming.derive_relation_name(arg_node.name)
            relation = DirectiveResolvers::WhereConditionsApplier.apply_has_argument(relation, arg_node.name, arg_value, relation_name)
          end

          apply_arg_builders(relation, args_h)
        rescue ::GraphQL::ExecutionError
          raise
        rescue StandardError => e
          Lighthouse::Config.handle_error(e)
          relation
        end

        # Compose argument-builder directives (@eq, @neq, @in, @notIn, @like,
        # @where, @orderBy) onto the relation, in SDL argument order, for each
        # field argument that carries one and that the client supplied a value
        # for.
        def apply_arg_builders(relation, args_h)
          return relation unless relation.respond_to?(:where)
          return relation unless @field_def.ast_node

          registry = Lighthouse::DirectiveRegistry.default

          (@field_def.ast_node.arguments || []).each do |arg_node|
            (arg_node.directives || []).each do |dnode|
              builder_class = registry.arg_builder_class(dnode.name)
              next unless builder_class

              value = Lighthouse::Support::Naming.fetch_arg(args_h, arg_node.name)
              next if value.nil?

              relation = builder_class.new(arg_node, dnode).handle_builder(relation, value)
            end
          end

          relation
        rescue ::GraphQL::ExecutionError
          raise
        rescue StandardError => e
          Lighthouse::Config.handle_error(e)
          relation
        end

        def extract_relation_name_from_directive(arg_node)
          directive = arg_node.directives.find { |dir| dir.name == 'whereHasConditions' }
          return nil unless directive

          relation_arg = directive.arguments.find { |arg| arg.name == 'relation' }
          return nil unless relation_arg

          relation_arg.value.respond_to?(:value) ? relation_arg.value.value : relation_arg.value
        rescue StandardError
          nil
        end

        def constantize_model(name)
          Lighthouse::Support::ModelResolver.constantize(name)
        end
      end
    end
  end
end
