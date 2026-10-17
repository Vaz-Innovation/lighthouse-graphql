# frozen_string_literal: true

module Lighthouse
  module Support
    # Field-argument plumbing shared by resolvers: plain-Ruby conversion, @inject,
    # @spread, and dot paths ("input.id", "*.id") into arguments and results.
    module Arguments
      module_function

      # The arguments a resolver class receives: @inject applied, then @spread.
      # Values keep their GraphQL input-object form except where spread.
      def prepare(field_def, args, context)
        values = inject(field_def.ast_node, shallow(args), context)
        spread(field_def.arguments, values)
      end

      # Arguments / input objects as a Hash with symbol keys, one level deep.
      def shallow(value)
        case value
        when ::GraphQL::Schema::InputObject then value.to_h.transform_keys(&:to_sym)
        when ::GraphQL::Execution::Interpreter::Arguments then value.keyword_arguments.dup
        when Hash then value.transform_keys(&:to_sym)
        else {}
        end
      end

      # Input objects, arguments and nested collections as plain Ruby values.
      def plain(value)
        case value
        when ::GraphQL::Schema::InputObject then plain(value.to_h)
        when ::GraphQL::Execution::Interpreter::Arguments then plain(value.keyword_arguments)
        when Hash then value.to_h { |k, v| [k.to_sym, plain(v)] }
        when Array then value.map { |v| plain(v) }
        else value
        end
      end

      # @inject(context: "current_user.id", name: "user_id"): server-side values
      # written into the arguments, so clients cannot set them.
      def inject(field_ast_node, values, context)
        directives = (field_ast_node&.directives || []).select { |d| d.name == 'inject' }
        directives.reduce(values) do |acc, directive|
          from = DirectiveArgs.literal(directive, 'context').to_s
          to = DirectiveArgs.literal(directive, 'name').to_s
          set_path(acc, to.split('.'), dig(context, from).first)
        end
      end

      # Merge every @spread argument's input object into its parent, recursively.
      def spread(argument_defs, values)
        by_keyword = keyword_index(argument_defs)
        values.each_with_object({}) do |(key, value), out|
          argument = by_keyword[key.to_sym]
          if argument && spread?(argument) && !value.nil?
            out.merge!(spread(argument.type.unwrap.arguments, shallow(value)))
          else
            out[key] = value
          end
        end
      end

      def spread?(argument)
        (argument.ast_node&.directives || []).any? { |d| d.name == 'spread' }
      end

      def keyword_index(argument_defs)
        (argument_defs || {}).values.to_h { |argument| [argument.keyword, argument] }
      end

      # Every value at a dot `path` under `root`; `*` walks each list element.
      # GraphQL names are matched in their snake_case form. Always an Array.
      def dig(root, path)
        path.to_s.split('.').reduce([root]) do |nodes, segment|
          nodes.flat_map do |node|
            next [] if node.nil?
            next list(node) || [node] if segment == '*'

            [read(node, segment)]
          end
        end.compact
      end

      # The items of a collection (Array, Set, relation), or nil for a single
      # object — records and Structs answer #to_a too, so that test won't do.
      def list(value)
        case value
        when Array then value
        when Set then value.to_a
        else value.to_a if defined?(::ActiveRecord::Relation) && value.is_a?(::ActiveRecord::Relation)
        end
      end

      def read(node, segment)
        keys = [segment, segment.underscore].uniq
        if node.respond_to?(:key?)
          keys.each do |key|
            return node[key.to_sym] if node.key?(key.to_sym)
            return node[key] if node.key?(key)
          end
          return nil if node.is_a?(Hash)
        end
        method = keys.reverse.find { |key| node.respond_to?(key) }
        method ? node.public_send(method) : nil
      end

      def set_path(values, segments, value)
        key, *rest = segments
        key = key.underscore.to_sym
        copy = values.dup
        copy[key] = rest.empty? ? value : set_path(shallow(copy[key]), rest, value)
        copy
      end
    end
  end
end
