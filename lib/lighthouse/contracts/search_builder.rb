# frozen_string_literal: true

require_relative 'directive'

# An argument directive that also writes to the full-text search, as PHP
# Lighthouse's ScoutBuilderDirective: when the client searches, the directives
# of the other arguments it sends narrow the Search::Query instead of the
# relation, if they include this contract (@eq, @trashed, @builder on an
# argument). Any other argument directive the client sends with a search is
# an error, because a search engine cannot apply it.
#
# Implementors, built with (arg_node, directive_node), provide
# `#handle_search_builder(query, value)` returning the query.
module Lighthouse::Contracts::SearchBuilder
  include Lighthouse::Contracts::Directive
end
