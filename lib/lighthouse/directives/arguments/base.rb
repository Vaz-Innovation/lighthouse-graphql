# frozen_string_literal: true

module Lighthouse
  module GraphQL
    module Directives
      module Arguments
        # Base class for argument-builder directives (@eq, @neq, @in, @notIn,
        # @like, @where, @orderBy). Each receives the argument AST node and the
        # directive AST node, and composes a constraint onto an ActiveRecord
        # relation given the client-supplied value for that argument.
        class Base
          include Lighthouse::Contracts::ArgBuilder

          def initialize(arg_node, directive_node)
            @arg_node = arg_node
            @directive_node = directive_node
          end

          # @return relation
          def handle_builder(_relation, _value)
            raise NotImplementedError
          end

          private

          # Column to filter on: the directive's `key:` argument if present,
          # otherwise the snake_case form of the GraphQL argument name.
          def column
            Lighthouse::Support::DirectiveArgs.literal(@directive_node, 'key') ||
              Lighthouse::Support::Naming.attribute(@arg_node.name)
          end

          def arel_column(relation)
            relation.klass.arel_table[column]
          end
        end
      end
    end
  end
end
