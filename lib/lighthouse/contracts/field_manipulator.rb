# frozen_string_literal: true

require_relative 'directive'

# A directive that mutates the schema AST before it is built, e.g. @paginate
# and the relationship directives injecting Connection/Paginator types, or
# @orderBy generating its column enum.
#
# Implementors provide (at the class level)
# `manipulate_field_definition(manipulation_context, parent, field, directive)`.
module Lighthouse::Contracts::FieldManipulator
  include Lighthouse::Contracts::Directive
end
