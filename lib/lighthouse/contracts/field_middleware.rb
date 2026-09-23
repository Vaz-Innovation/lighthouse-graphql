# frozen_string_literal: true

require_relative 'directive'

module Lighthouse
  module Contracts
    # A directive that wraps an existing field resolver, e.g. @auth wrapping the
    # underlying resolver to enforce authentication.
    #
    # Implementors provide `#wrap_resolver(next_resolver)` returning a new
    # `#call(obj, args, ctx)` lambda that may invoke `next_resolver`.
    module FieldMiddleware
      include Directive
    end
  end
end
