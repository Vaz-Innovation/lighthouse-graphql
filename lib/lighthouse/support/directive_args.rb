# frozen_string_literal: true

module Lighthouse
  module Support
    # Extracts argument values from a GraphQL directive AST node, unwrapping the
    # various value-node shapes (scalar literals, enums, lists) into plain Ruby
    # values. Consolidates the repeated
    # `arg.value.respond_to?(:value) ? arg.value.value : arg.value` pattern.
    module DirectiveArgs
      module_function

      # Return the literal value of directive argument `name`, or nil.
      def literal(directive_node, name)
        return nil unless directive_node.respond_to?(:arguments)

        arg = directive_node.arguments&.find { |a| a.name == name.to_s }
        return nil unless arg

        unwrap(arg.value)
      end

      def unwrap(value)
        if value.respond_to?(:value)
          value.value
        elsif value.is_a?(Array)
          value.map { |item| unwrap(item) }
        else
          value
        end
      end
    end
  end
end
