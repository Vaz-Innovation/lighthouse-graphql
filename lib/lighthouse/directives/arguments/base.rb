# frozen_string_literal: true

# Base class for argument-builder directives (@eq, @neq, @in, @notIn,
# @like, @where, @orderBy). Each receives the argument AST node and the
# directive AST node, and composes a constraint onto an ActiveRecord
# relation given the client-supplied value for that argument.
class Lighthouse::GraphQL::Directives::Arguments::Base
  include Lighthouse::Contracts::ArgBuilder

  # The `key` argument's SDL, which most of them take.
  KEY_ARGUMENT = Lighthouse::GraphQL::DirectiveResolvers::BaseDirectiveResolver.argument_sdl(
    'key: String', "The column to filter on. Defaults to the argument's name in snake_case."
  )

  def self.argument_sdl(...) = Lighthouse::GraphQL::DirectiveResolvers::BaseDirectiveResolver.argument_sdl(...)

  # The SDL of a filter directive: `description`, then its arguments (`key` by default).
  def self.sdl(name, description, arguments = KEY_ARGUMENT)
    parentheses = "(\n#{arguments}\n)" if arguments
    <<~GRAPHQL.chomp
      """
      #{description}
      """
      directive @#{name}#{parentheses} on ARGUMENT_DEFINITION | INPUT_FIELD_DEFINITION
    GRAPHQL
  end

  # Does the directive, as the SDL writes it (`directive_node`), change the field's
  # query? Most do; one that does not (@limit without `builder: true`, which cuts
  # what the field resolved) leaves a search outside the database alone.
  def self.changes_query?(_directive_node) = true

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
