# frozen_string_literal: true

require_relative 'directive'

module Lighthouse
  module Contracts
    # A directive on a field ARGUMENT that mutates the schema AST before build,
    # e.g. @whereConditions / @whereHasConditions generating input/enum types and
    # swapping the `_` placeholder argument type.
    #
    # Implementors provide (at the class level)
    # `manipulate_argument_definition(manipulation_context, parent, field, arg, directive)`.
    module ArgManipulator
      include Directive
    end
  end
end
