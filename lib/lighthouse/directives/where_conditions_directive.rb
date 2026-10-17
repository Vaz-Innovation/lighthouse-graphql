# frozen_string_literal: true

require 'graphql'

class Lighthouse::GraphQL::Directives::WhereConditionsDirective
  SQLOPERATOR_TYPE_NAME = 'SQLOperator'
  MIXED_SCALAR_NAME = 'Mixed'
  PLACEHOLDER_SCALAR_NAME = '_'
  DEFINITIONS = {
    'whereConditions' =>
      'directive @whereConditions(columns: [String!], columnsEnum: String) on ARGUMENT_DEFINITION',
    'whereHasConditions' =>
      'directive @whereHasConditions(relation: String, columns: [String!], columnsEnum: String) on ARGUMENT_DEFINITION'
  }.freeze

  # Default description of an undocumented argument, per directive.
  ARGUMENT_DESCRIPTIONS = {
    'whereConditions' => 'Filter results by field conditions.',
    'whereHasConditions' => 'Filter results by related records conditions.'
  }.freeze

  # Types whose field arguments may carry the directives.
  OBJECT_DEFINITIONS = [
    ::GraphQL::Language::Nodes::ObjectTypeDefinition,
    ::GraphQL::Language::Nodes::InterfaceTypeDefinition
  ].freeze

  # Supported operators in the generated GraphQL input type performance.
  SUPPORTED_OPERATORS = %w[EQ NEQ GT GTE LT LTE IN NIN CONTAINS STARTS_WITH ENDS_WITH IS_NULL IS_NOT_NULL].freeze

  # `definitions` maps every type name to its generated SDL. Names the schema
  # already declares are seeded with nil, so they are never generated again
  # and drop out of the output.
  def self.manipulate(sdl)
    return sdl unless sdl.is_a?(String) && !sdl.empty?

    ast = parse(sdl)
    return sdl unless ast

    definitions = ast.definitions.filter_map { |defn| defn.respond_to?(:name) ? defn.name : nil }.index_with(nil)
    each_where_argument(ast) do |type_def, field, arg, directive|
      expand_argument(type_def, field, arg, directive, definitions)
    end
    define_utility_types(ast, definitions)

    generated = definitions.values.compact
    return sdl if generated.empty?

    modified_sdl = ::GraphQL::Language::Printer.new.print(ast)
    "#{modified_sdl}\n\n#{generated.join("\n\n")}"
  end

  def self.parse(sdl)
    ::GraphQL::Language::Parser.parse(sdl)
  rescue StandardError => e
    warn("Lighthouse::GraphQL::Directives::WhereConditionsDirective: parse failed: #{e.class}: #{e.message}")
    nil
  end

  # Yields every object/interface field argument carrying @whereConditions or
  # @whereHasConditions, along with that directive.
  def self.each_where_argument(ast)
    each_field(ast) do |type_def, field|
      (field.arguments || []).each do |arg|
        directive = arg.directives&.find { |d| DEFINITIONS.key?(d.name) }
        yield type_def, field, arg, directive if directive
      end
    end
  end

  def self.each_field(ast)
    ast.definitions.each do |type_def|
      next unless OBJECT_DEFINITIONS.any? { |kind| type_def.is_a?(kind) }

      (type_def.fields || []).each { |field| yield type_def, field }
    end
  end

  # Points the argument at its generated input type and defines the types it
  # needs: the conditions input, its HAS relation input and the column enum.
  def self.expand_argument(type_def, field, arg, directive, definitions)
    describe_argument(arg, directive)

    prefix = "#{camelize(type_def.name)}#{camelize(field.name)}#{camelize(arg.name)}"
    input_type_name = "#{prefix}WhereConditions"
    column_enum_name = "#{prefix}Column"
    relation_input_name = "#{input_type_name}Relation"

    apply_arg_type_replacement(arg, input_type_name)

    # Build input type if needed.
    define_once(definitions, input_type_name) do
      build_where_condition_input(input_type_name, column_enum_name, relation_input_name, directive)
    end

    # Build relation type for HAS support in whereConditions
    if directive.name == 'whereConditions'
      define_once(definitions, relation_input_name) { build_where_condition_relation_input(relation_input_name, input_type_name) }
    end

    define_column_enum(definitions, column_enum_name, directive)
  end

  def self.describe_argument(arg, directive)
    return if arg.description.present?

    arg.instance_variable_set(:@description, ARGUMENT_DESCRIPTIONS.fetch(directive.name))
  end

  # Build column enum type unless columnsEnum is provided.
  def self.define_column_enum(definitions, column_enum_name, directive)
    return unless directive_argument_value(directive, 'columnsEnum').nil?

    columns = directive_argument_value(directive, 'columns')
    return if Array(columns).empty?

    define_once(definitions, column_enum_name) { build_column_enum(column_enum_name, columns) }
  end

  def self.define_utility_types(ast, definitions)
    # Append base utility types only once
    define_once(definitions, SQLOPERATOR_TYPE_NAME) { build_sql_operator_enum }
    define_once(definitions, MIXED_SCALAR_NAME) { "scalar #{MIXED_SCALAR_NAME}" }

    # Some SDL files use `_` as a placeholder input type, even when no
    # whereConditions directive is attached (e.g. WIP schema pieces). If we
    # don't define it, GraphQL-Ruby raises UnresolvedLateBoundTypeError.
    return unless contains_placeholder_type?(ast)

    define_once(definitions, PLACEHOLDER_SCALAR_NAME) { "scalar #{PLACEHOLDER_SCALAR_NAME}" }
  end

  def self.define_once(definitions, name)
    definitions[name] = yield unless definitions.key?(name)
  end

  def self.apply_arg_type_replacement(arg, input_type_name)
    case arg.type
    when ::GraphQL::Language::Nodes::TypeName
      arg.instance_variable_set(:@type, ::GraphQL::Language::Nodes::TypeName.new(name: input_type_name)) if arg.type.name == '_'
    when ::GraphQL::Language::Nodes::NonNullType
      inner = arg.type.of_type
      return unless inner.is_a?(::GraphQL::Language::Nodes::TypeName) && inner.name == '_'

      new_type = ::GraphQL::Language::Nodes::NonNullType.new(of_type: ::GraphQL::Language::Nodes::TypeName.new(name: input_type_name))
      arg.instance_variable_set(:@type, new_type)
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
    values = Array(columns).filter_map do |column|
      value = column.to_s
      key = value.gsub(/[^0-9A-Za-z]/, '_').upcase
      "  #{key}"
    end.uniq

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

    value = unwrap_value(arg.value)
    name == 'columns' && value.is_a?(Array) ? value.map { |item| unwrap_value(item) } : value
  end

  # Supports both Babel-style AST and raw Ruby value.
  def self.unwrap_value(node)
    node.respond_to?(:value) ? node.value : node
  end

  def self.contains_placeholder_type?(document)
    document.definitions.any? do |defn|
      next false unless defn.respond_to?(:fields) && defn.fields.respond_to?(:any?)

      (defn.fields || []).any? { |field| placeholder_argument?(field) }
    end
  rescue StandardError
    false
  end

  def self.placeholder_argument?(field)
    arguments = (field.respond_to?(:arguments) && field.arguments) || []
    arguments.any? { |arg| type_references_placeholder?(arg.type) }
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
    value.to_s.split(/[_\s]+/).map { |part| part.slice(0, 1).upcase + part.slice(1..).to_s }.join
  end
end
