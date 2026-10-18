# frozen_string_literal: true

require_relative 'directive'

# A directive on a FIELD that constrains the query of the field's resolver
# whatever the client sends, e.g. @orderBy(column:, direction:) on a field.
# Applied after the argument builders, as PHP Lighthouse's FieldBuilderDirective.
#
# Implementors, built with (field_node, directive_node), provide
# `#handle_field_builder(relation)` returning a relation.
module Lighthouse::Contracts::FieldBuilder
  include Lighthouse::Contracts::Directive
end
