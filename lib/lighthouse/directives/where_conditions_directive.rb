# frozen_string_literal: true

require 'graphql'

module Lighthouse
  module GraphQL
    module Directives
      class WhereConditionsDirective
        SQLOPERATOR_TYPE_NAME = 'SQLOperator'.freeze
        MIXED_SCALAR_NAME = 'Mixed'.freeze
        PLACEHOLDER_SCALAR_NAME = '_'.freeze

        # Supported operators in the generated GraphQL input type performance.
        SUPPORTED_OPERATORS = %w[EQ NEQ GT GTE LT LTE IN NIN CONTAINS STARTS_WITH ENDS_WITH IS_NULL IS_NOT_NULL].freeze

        def self.manipulate(sdl)
          return sdl unless sdl.is_a?(String) && !sdl.empty?
          begin
            ast = ::GraphQL::Language::Parser.parse(sdl)
          rescue => e
            warn("Lighthouse::GraphQL::Directives::WhereConditionsDirective: parse failed: #{e.class}: #{e.message}")
            return sdl
          end
          existing_defs = ast.definitions.map { |defn| defn.respond_to?(:name) ? defn.name : nil }.compact

          generated = []

          object_types = ast.definitions.select do |defn|
            defn.is_a?(::GraphQL::Language::Nodes::ObjectTypeDefinition) || defn.is_a?(::GraphQL::Language::Nodes::InterfaceTypeDefinition)
          end

          object_types.each do |type_def|
            (type_def.fields || []).each do |field|
              (field.arguments || []).each do |arg|
                directive = arg.directives&.find { |d| %w[whereConditions whereHasConditions].include?(d.name) }
                next unless directive

                if arg.description.nil? || arg.description.empty?
                  arg.instance_variable_set(
                    :@description,
                    directive.name == 'whereHasConditions' ? 'Filter results by related records conditions.' : 'Filter results by field conditions.'
                  )
                end

                input_type_name = "#{camelize(type_def.name)}#{camelize(field.name)}#{camelize(arg.name)}WhereConditions"
                column_enum_name = "#{camelize(type_def.name)}#{camelize(field.name)}#{camelize(arg.name)}Column"
                relation_input_name = "#{input_type_name}Relation"

                apply_arg_type_replacement(arg, input_type_name)

                # Build input type if needed.
                unless existing_defs.include?(input_type_name)
                  generated << build_where_condition_input(input_type_name, column_enum_name, relation_input_name, directive)
                  existing_defs << input_type_name
                end

                # Build relation type for HAS support in whereConditions
                if directive.name == 'whereConditions' && !existing_defs.include?(relation_input_name)
                  generated << build_where_condition_relation_input(relation_input_name, input_type_name)
                  existing_defs << relation_input_name
                end

                # Build column enum type unless columnsEnum is provided.
                columns_enum = directive_argument_value(directive, 'columnsEnum')
                columns = directive_argument_value(directive, 'columns')
                if columns_enum.nil? && columns && !columns.empty? && !existing_defs.include?(column_enum_name)
                  generated << build_column_enum(column_enum_name, columns)
                  existing_defs << column_enum_name
                end
              end
            end
          end

          # Append base utility types only once
          unless existing_defs.include?(SQLOPERATOR_TYPE_NAME)
            generated << build_sql_operator_enum
            existing_defs << SQLOPERATOR_TYPE_NAME
          end

          unless existing_defs.include?(MIXED_SCALAR_NAME)
            generated << "scalar #{MIXED_SCALAR_NAME}"
            existing_defs << MIXED_SCALAR_NAME
          end

          # Some SDL files use `_` as a placeholder input type, even when no
          # whereConditions directive is attached (e.g. WIP schema pieces). If we
          # don't define it, GraphQL-Ruby raises UnresolvedLateBoundTypeError.
          if contains_placeholder_type?(ast) && !existing_defs.include?(PLACEHOLDER_SCALAR_NAME)
            generated << "scalar #{PLACEHOLDER_SCALAR_NAME}"
            existing_defs << PLACEHOLDER_SCALAR_NAME
          end

          return sdl if generated.empty?

          modified_sdl = ::GraphQL::Language::Printer.new.print(ast)
          modified_sdl + "\n\n" + generated.join("\n\n")
        end

        def self.apply_arg_type_replacement(arg, input_type_name)
          case arg.type
          when ::GraphQL::Language::Nodes::TypeName
            if arg.type.name == '_'
              new_type = ::GraphQL::Language::Nodes::TypeName.new(name: input_type_name)
              arg.instance_variable_set(:@type, new_type)
            end
          when ::GraphQL::Language::Nodes::NonNullType
            inner = arg.type.of_type
            if inner.is_a?(::GraphQL::Language::Nodes::TypeName) && inner.name == '_'
              arg.instance_variable_set(:@type, ::GraphQL::Language::Nodes::NonNullType.new(of_type: ::GraphQL::Language::Nodes::TypeName.new(name: input_type_name)))
            end
          end
        end

        def self.build_where_condition_input(type_name, column_enum_name, relation_type_name, directive)
          column_type = directive_argument_value(directive, 'columnsEnum') || column_enum_name

          fields = []
          fields << "  column: #{column_type}"
          fields << "  operator: #{SQLOPERATOR_TYPE_NAME} = EQ"
          fields << "  value: #{MIXED_SCALAR_NAME}"
          fields << "  AND: [#{type_name}!]"
          fields << "  OR: [#{type_name}!]"
          fields << "  HAS: #{relation_type_name}" if directive.name == 'whereConditions'

          <<~TEXT.strip
            input #{type_name} {
            #{fields.join("\n")}
            }
          TEXT
        end

        def self.build_where_condition_relation_input(type_name, condition_type_name)
          <<~TEXT.strip
            input #{type_name} {
              relation: String!
              operator: #{SQLOPERATOR_TYPE_NAME} = GTE
              amount: Int = 1
              condition: #{condition_type_name}
            }
          TEXT
        end

        def self.build_column_enum(name, columns)
          values = Array(columns).map do |column|
            value = column.to_s
            key = value.gsub(/[^0-9A-Za-z]/, '_').upcase
            "  #{key}"
          end.compact.uniq

          <<~TEXT.strip
            enum #{name} {
            #{values.join("\n")}
            }
          TEXT
        end

        def self.build_sql_operator_enum
          values = SUPPORTED_OPERATORS.map { |op| "  #{op}" }
          <<~TEXT.strip
            enum #{SQLOPERATOR_TYPE_NAME} {
            #{values.join("\n")}
            }
          TEXT
        end

        def self.directive_argument_value(directive, name)
          arg = directive.arguments&.find { |a| a.name == name }
          return nil unless arg

          # Supports both Babel-style AST and raw Ruby value.
          value = arg.value.respond_to?(:value) ? arg.value.value : arg.value

          if name == 'columns' && value.is_a?(Array)
            value.map { |it| it.respond_to?(:value) ? it.value : it }
          else
            value
          end
        end

        def self.contains_placeholder_type?(document)
          document.definitions.any? do |defn|
            next false unless defn.respond_to?(:fields) && defn.fields.respond_to?(:any?)
            (defn.fields || []).any? do |field|
              (field.respond_to?(:arguments) ? field.arguments || [] : []).any? { |arg| type_references_placeholder?(arg.type) }
            end
          end
        rescue StandardError
          false
        end

        def self.type_references_placeholder?(type_node)
          case type_node
          when ::GraphQL::Language::Nodes::TypeName
            type_node.name == PLACEHOLDER_SCALAR_NAME
          when ::GraphQL::Language::Nodes::NonNullType, ::GraphQL::Language::Nodes::ListType
            type_references_placeholder?(type_node.of_type)
          else
            false
          end
        end

        def self.camelize(value)
          value.to_s.split(/[_\s]+/).map { |part| part.slice(0,1).upcase + part.slice(1..).to_s }.join
        end
      end
    end
  end
end
