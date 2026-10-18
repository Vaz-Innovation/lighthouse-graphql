# frozen_string_literal: true

require_relative 'directive'

# A directive on a field ARGUMENT that rewrites the schema before it is built,
# as PHP Lighthouse's ArgManipulator: @whereConditions, @whereHasConditions and
# @orderBy generate the input types of an argument written with the `_`
# placeholder, and type it with them.
#
# Implementors, built with (arg_node, directive_node), provide
# `#manipulate_arg_definition(document_ast, field_node, type_node)` returning
# the argument node (graphql-ruby's nodes are immutable: `arg.merge(type: ...)`).
# New types go in the Lighthouse::GraphQL::DocumentAST (`define_type`).
# ASTBuilder calls it for every argument of an object or interface field.
module Lighthouse::Contracts::ArgManipulator
  include Lighthouse::Contracts::Directive
end
