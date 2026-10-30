# frozen_string_literal: true

# The graphql-ruby trace module that keeps, while a streamed response with
# @defer runs, the objects its deferred fragments will need: those of the
# object fields a fragment adds selections to, which the rest of the query
# resolved (Plan). Defer.use adds it to a trace mode of its own (MODE), which Run
# picks for those requests only: no other request runs it.
module Lighthouse::GraphQL::Incremental::Recorder
  MODE = :lighthouse_incremental

  def execute_field(query:, ast_node:, **options)
    result = super
    keep(query, ast_node, result) unless query.schema.lazy?(result)
    result
  end

  def execute_field_lazy(query:, ast_node:, **options)
    result = super
    keep(query, ast_node, result)
    result
  end

  private

  def keep(query, ast_node, result)
    state = query.context[Lighthouse::GraphQL::Incremental::State::CONTEXT_KEY]
    state.keep(query.context[:current_path], result) if state&.wanted?(ast_node.alias || ast_node.name)
  end
end
