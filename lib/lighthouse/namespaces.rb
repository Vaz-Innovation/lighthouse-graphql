# frozen_string_literal: true

# The namespaces the library's files live in. Every other file opens its class
# or module compactly (`class Lighthouse::GraphQL::DirectiveResolvers::Base`),
# which needs the enclosing namespaces to exist already, so they are defined
# here, first.
module Lighthouse
  module Contracts; end
  module Events; end
  module Generators; end
  module OrderBy; end
  module Support; end
  module WhereConditions; end

  module GraphQL
    module DataloaderSources; end
    module DirectiveResolvers; end

    module Directives
      module Arguments; end
    end
  end
end
