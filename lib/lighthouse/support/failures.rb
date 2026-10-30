# frozen_string_literal: true

# How the work a field's directives do fails: its filters
# (BaseDirectiveResolver#apply_where_filters) and the engine requests a search
# makes (Search::Result), which may run later, as a page resolves. The same
# way wherever it runs, never answering the rows a failing part would have
# left out.
module Lighthouse::Support::Failures
  module_function

  # The block, failing the field when it raises. A client's error is raised as it
  # is. A schema error found only as the query runs (a field whose model the build
  # could not tell) is reported (Config.on_error) and the client reads it. Any
  # other (a builder's, an engine's) is reported and raised as it is, so that the
  # schema's rescue_from maps it, as any resolver's error; unmapped, it is
  # graphql-ruby's.
  def strictly(context)
    yield
  rescue ::GraphQL::ExecutionError
    raise
  rescue Lighthouse::DefinitionError => e
    Lighthouse::Config.handle_error(e, context)
    raise ::GraphQL::ExecutionError, e.message.end_with?('.') ? e.message : "#{e.message}."
  rescue StandardError => e
    Lighthouse::Config.handle_error(e, context)
    raise
  end
end
