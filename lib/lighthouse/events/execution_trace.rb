# frozen_string_literal: true

# The graphql-ruby trace module SchemaGenerator.build installs on every schema,
# dispatching the execution events (StartExecution, BuildExtensionsResponse,
# ManipulateResult, EndExecution) around each query of a multiplex. A query
# runs through a multiplex even on its own. With nothing listening it adds one
# lookup per request.
module Lighthouse::Events::ExecutionTrace
  EVENTS = [
    Lighthouse::Events::StartExecution, Lighthouse::Events::BuildExtensionsResponse,
    Lighthouse::Events::ManipulateResult, Lighthouse::Events::EndExecution
  ].freeze

  def execute_multiplex(multiplex:)
    return super unless EVENTS.any? { |event| Lighthouse::Events.listening?(event) }

    multiplex.queries.each { |query| Lighthouse::Events::ExecutionTrace.start(multiplex.schema, query) }
    results = super
    multiplex.queries.each { |query| Lighthouse::Events::ExecutionTrace.finish(query) }
    results
  end

  class << self
    def start(schema, query)
      Lighthouse::Events.dispatch(
        Lighthouse::Events::StartExecution.new(schema, query.document, query.provided_variables, query.operation_name, query.context)
      )
    end

    # The query's result Hash is final but for the listeners: they add
    # extensions and may change it in place before the response is built.
    def finish(query)
      result = query.result_values
      return unless result.is_a?(Hash)

      merge_extensions(result, Lighthouse::Events.dispatch(Lighthouse::Events::BuildExtensionsResponse.new(result, nil)))
      manipulate = Lighthouse::Events::ManipulateResult.new(result)
      Lighthouse::Events.dispatch(manipulate)
      result.replace(manipulate.result) unless manipulate.result.equal?(result)
      Lighthouse::Events.dispatch(Lighthouse::Events::EndExecution.new(result))
    end

    def merge_extensions(result, responses)
      responses = responses.flatten.grep(Lighthouse::Events::ExtensionsResponse)
      return if responses.empty?

      extensions = (result['extensions'] ||= {})
      responses.each { |response| extensions[response.key.to_s] = response.content }
    end
  end
end
