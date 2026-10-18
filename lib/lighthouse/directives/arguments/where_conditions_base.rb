# frozen_string_literal: true

require_relative 'base'

# What @whereConditions and @whereHasConditions share, as PHP Lighthouse's
# WhereConditionsBaseDirective: an argument written with the `_` placeholder
# gets the input types the directive generates (Lighthouse::WhereConditions::Types),
# and the client's value becomes WHERE conditions on the field's query
# (Lighthouse::WhereConditions::Handler).
#
#   type Query {
#     people(where: _ @whereConditions(columns: ["age", "type"])): [Person!]! @all
#     users(hasPosts: _ @whereHasConditions(columns: ["title"])): [User!]! @all
#   }
#
# `columns:` restricts the columns to an enum generated from them,
# `columnsEnum:` to an enum of the schema's; without either the column is any
# identifier the client sends.
class Lighthouse::GraphQL::Directives::Arguments::WhereConditionsBase < Lighthouse::GraphQL::Directives::Arguments::Base
  include Lighthouse::Contracts::ArgManipulator

  GeneratedTypes = Lighthouse::GraphQL::Directives::GeneratedTypes

  COLUMN_ARGUMENTS = <<~GRAPHQL.chomp
    """
    Restrict the allowed column names to a well-defined list.
    This improves introspection capabilities and security.
    Mutually exclusive with `columnsEnum`.
    """
    columns: [String!]

    """
    Use an existing enumeration type to restrict the allowed columns to a predefined list.
    This allows you to re-use the same enum for multiple fields.
    Mutually exclusive with `columns`.
    """
    columnsEnum: String

    """
    A class that applies the client given conditions to the query: `call(relation, conditions)`
    answers the relation. "Class@method" names another method. Looked up in the builders namespaces.
    """
    handler: String
  GRAPHQL

  # The argument, typed with the conditions input generated for it.
  def manipulate_arg_definition(document_ast, field, type)
    path = "the `#{@arg_node.name}` argument of #{type.name}.#{field.name}"
    arg = GeneratedTypes.describe(@arg_node, self.class::DESCRIPTION)
    types = Lighthouse::WhereConditions::Types
    unless GeneratedTypes.allowed_columns?(@directive_node)
      types.define_default(document_ast)
      return GeneratedTypes.replace_placeholder(arg, types::DEFAULT)
    end

    name = GeneratedTypes.qualified_arg_type(@arg_node, field, type) + self.class::SUFFIX
    types.define(document_ast, name, GeneratedTypes.columns_enum(document_ast, @directive_node, @arg_node, field, type), path)
    GeneratedTypes.replace_placeholder(arg, name)
  end

  def handle_builder(relation, value)
    return relation if value.nil?

    handler.call(relation, conditions(value)) || relation
  end

  private

  def conditions(value) = value

  # Lighthouse::WhereConditions::Handler, or the class (or instance) `handler:` names.
  def handler
    reference = Lighthouse::Support::DirectiveArgs.literal(@directive_node, 'handler')
    return Lighthouse::WhereConditions::Handler unless reference

    class_name, method_name = reference.to_s.split('@', 2)
    klass = Lighthouse::Support::ModelResolver.constantize(class_name, namespaces: Lighthouse::Config.namespaces[:builders])
    raise Lighthouse::DefinitionError, "@#{@directive_node.name}(handler: \"#{reference}\"): no class #{class_name}" unless klass

    method_name = method_name.presence || 'call'
    receiver = klass.respond_to?(method_name) ? klass : klass.new
    receiver.method(method_name)
  end
end
