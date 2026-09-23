# frozen_string_literal: true

module Lighthouse
  # Contracts are duck-typed marker modules that mirror the PHP Lighthouse
  # directive interfaces. A directive class includes whichever contracts it
  # fulfils; the DirectiveRegistry and SchemaGenerator detect capabilities via
  # `klass.include?(Contracts::X)` and invoke the corresponding hook.
  module Contracts
    # Base marker. Every Lighthouse directive class includes this.
    #
    # Implementors are expected to expose (at the class level):
    #   - `directive_name` -> String   the SDL name without the leading '@'
    #   - `definition`     -> String?  the SDL `directive @name(...) on ...` line
    module Directive
    end
  end
end
