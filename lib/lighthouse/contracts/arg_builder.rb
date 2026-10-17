# frozen_string_literal: true

require_relative 'directive'

# A directive on a field ARGUMENT that composes a constraint onto an
# ActiveRecord relation at resolve time, e.g. @eq, @neq, @in, @notIn, @like,
# @where, @orderBy. These compose in SDL argument order via the
# ArgBuilderPipeline.
#
# Implementors provide `#handle_builder(relation, value)` returning a relation.
module Lighthouse::Contracts::ArgBuilder
  include Lighthouse::Contracts::Directive
end
