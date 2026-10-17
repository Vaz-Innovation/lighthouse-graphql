# frozen_string_literal: true

require_relative 'directive'

# A directive that wraps an existing field resolver, e.g. @auth wrapping the
# underlying resolver to enforce authentication.
#
# Implementors provide `#wrap_resolver(next_resolver)` returning a new
# `#call(obj, args, ctx)` lambda that may invoke `next_resolver`.
module Lighthouse::Contracts::FieldMiddleware
  include Lighthouse::Contracts::Directive
end
