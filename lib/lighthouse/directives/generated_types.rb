# frozen_string_literal: true

# What the argument manipulators that generate types share, as PHP
# Lighthouse's ASTHelper and GeneratesColumnsEnum: the qualified name of an
# argument's types, the enum of its allowed columns, and the `_` placeholder
# the argument is written with.
#
#   type Query { posts(orderBy: _ @orderBy(columns: ["posted_at"])): [Post!]! @all }
#
# names Query.posts(orderBy:)'s types QueryPostsOrderBy..., its columns enum
# QueryPostsOrderByColumn { POSTED_AT @enum(value: "posted_at") }.
module Lighthouse::GraphQL::Directives::GeneratedTypes
  PLACEHOLDER = '_'

  module_function

  # Studly(Type) + Studly(field) + Studly(argument): QueryPostsOrderBy.
  def qualified_arg_type(arg, field, type)
    [type.name, field.name, arg.name].map { |name| studly(name) }.join
  end

  def studly(name)
    name.to_s.split(/[_\s-]+/).map { |part| part[0].to_s.upcase + part[1..].to_s }.join
  end

  # `argument` of the directive as a Ruby value (`columns: ["a"]` -> ["a"]), or nil.
  def directive_value(directive, name)
    Lighthouse::Support::DirectiveArgs.literal(directive, name)
  end

  def directive_argument?(directive, name)
    directive.arguments.any? { |argument| argument.name == name }
  end

  # Raises unless at most one of `names` is given to the directive.
  def mutually_exclusive!(directive, names)
    given = names.select { |name| directive_argument?(directive, name) }
    return if given.size <= 1

    raise Lighthouse::DefinitionError,
          "The @#{directive.name} directive can only have one of the following arguments: #{names.map { |n| "`#{n}`" }.join(', ')}."
  end

  # Does the directive restrict the columns (`columns:` or `columnsEnum:`)?
  def allowed_columns?(directive)
    mutually_exclusive!(directive, %w[columns columnsEnum])
    directive_argument?(directive, 'columns') || directive_argument?(directive, 'columnsEnum')
  end

  # The enum of the allowed columns: `columnsEnum:`, or one generated from
  # `columns:` as <QualifiedArgType>Column.
  def columns_enum(document_ast, directive, arg, field, type)
    enum = directive_value(directive, 'columnsEnum')
    return enum if enum

    name = "#{qualified_arg_type(arg, field, type)}Column"
    define_columns_enum(document_ast, name, directive_value(directive, 'columns'), "#{type.name}.#{field.name}.#{arg.name}")
    name
  end

  def define_columns_enum(document_ast, name, columns, path)
    values = Array(columns).map { |column| %(  #{enum_value_name(column)} @enum(value: "#{column}")) }.uniq
    document_ast.put_type(parse(<<~GRAPHQL))
      "Allowed column names for #{path}."
      enum #{name} {
      #{values.join("\n")}
      }
    GRAPHQL
  end

  # `posted_at` -> POSTED_AT, `roles.id` -> ROLES_ID.
  def enum_value_name(column)
    name = column.to_s.gsub(/[^0-9A-Za-z_]/, '_').upcase
    name.match?(/\A[0-9]/) ? "_#{name}" : name
  end

  # The argument with its type replaced by `type_string` ("[QueryPostsOrderByClause!]"),
  # when it is written with the `_` placeholder. An argument given a type of
  # its own keeps it.
  def replace_placeholder(arg, type_string)
    return arg unless placeholder?(arg.type)

    arg.merge(type: parse_type(type_string))
  end

  def placeholder?(type)
    type = type.of_type while type.respond_to?(:of_type)
    type.name == PLACEHOLDER
  end

  # The argument with `description`, unless it has one.
  def describe(arg, description)
    arg.description.to_s.empty? ? arg.merge(description: description) : arg
  end

  def parse(sdl)
    ::GraphQL::Language::Parser.parse(sdl).definitions.first
  end

  def parse_type(type_string)
    parse("input LighthouseTypeReference { field: #{type_string} }").fields.first.type
  end
end
