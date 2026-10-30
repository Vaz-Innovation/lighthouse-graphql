# frozen_string_literal: true

require 'active_support/concern'
require 'active_support/core_ext/class/attribute'
require 'json'

# A Rails controller concern that serves a Lighthouse schema: include it, name
# the schema, route to `execute`.
#
#   class GraphqlController < ApplicationController
#     include Lighthouse::GraphQL::Controller
#
#     lighthouse_schema AppSchema   # or 'AppSchema', or { AppSchema }, resolved per request
#
#     private
#
#     def graphql_context = { current_user: current_user }
#   end
#
# `execute` dispatches StartRequest, reads the variables (a JSON String, a Hash
# or parameters), runs the operation through PersistedQueries.execute (or
# PersistedQueries.multiplex for a batch, a JSON array body; a multipart
# request's operations, with its files, as MultipartRequest reads them), sets the
# Cache-Control header the selected fields' @cacheControl hints allow, renders
# the JSON and dispatches EndRequest. In development an error renders as JSON.
#
# A field's @throttle that renders past its limit (its `with:` method, or
# `head :too_many_requests`, rate_limit's default on Rails 7.2) ends the request
# with that response, as a before_action that renders does: the operation stops
# there (Performed), and `execute` renders nothing more.
#
# Hooks, private so they are not actions: `graphql_context` (default:
# `{ current_user: current_user }` when the controller has a current_user, else
# `{}`), `graphql_schema` and `graphql_variables(param)`, from
# Lighthouse::GraphQL::Operations, which also gives the controller's own actions
# `lighthouse_execute`. An action of its own wraps itself in
# `lighthouse_request { ... }` to get the request events; a nested call
# dispatches them once.
module Lighthouse::GraphQL::Controller
  extend ActiveSupport::Concern

  # Raised once a @throttle `with:` method has performed the response: control
  # flow, as `throw :abort` in a before_action, so no `rescue StandardError` (a
  # schema's rescue_from) catches it on its way out of the operation.
  class Performed < Exception; end # rubocop:disable Lint/InheritException

  # The client of a streamed response went away: writing to its stream failed.
  class Gone < StandardError; end

  include Lighthouse::GraphQL::Operations

  def execute
    lighthouse_request do
      operations = lighthouse_operations
      if operations.is_a?(Array)
        render json: lighthouse_batch(operations.map { |operation| lighthouse_hash(operation) })
      else
        lighthouse_respond(operations)
      end
    end
  rescue StandardError => e
    raise e unless lighthouse_render_development_error?(e)

    lighthouse_development_error(e)
  ensure
    # A streamed response ends when its stream is closed, after EndRequest.
    response.stream.close if @lighthouse_streaming
  end

  private

  # A multipart request's operation(s), a batch (a JSON array body), or the parameters.
  def lighthouse_operations
    Lighthouse::GraphQL::MultipartRequest.operations(params) || params[:_json] || params
  end

  # Parameters, or a Hash from a multipart request's JSON, read by key either way.
  def lighthouse_hash(operation)
    (operation.respond_to?(:to_unsafe_h) ? operation.to_unsafe_h : operation.to_h).with_indifferent_access
  end

  # `operation`: the request's parameters, or a multipart request's operation.
  def lighthouse_operation(operation = params)
    Lighthouse::GraphQL::PersistedQueries.execute(graphql_schema, **lighthouse_arguments(operation))
  end

  # Each operation gets its own context: `schema.multiplex`'s `context:` is the
  # multiplex's, which the queries' resolvers never see.
  def lighthouse_batch(operations)
    Lighthouse::GraphQL::PersistedQueries.multiplex(graphql_schema, operations.map { |operation| lighthouse_arguments(operation) })
  end

  # What PersistedQueries runs an operation with: its query, extensions, variables and
  # name, in the request's context.
  def lighthouse_arguments(operation)
    operation = operation.with_indifferent_access if operation.is_a?(Hash)
    { query: operation[:query], extensions: operation[:extensions], variables: graphql_variables(operation[:variables]),
      operation_name: operation[:operationName], context: lighthouse_context }
  end

  # One operation: answered whole, or streamed (Defer) when it asks for it.
  def lighthouse_respond(operation)
    return lighthouse_incremental(operation) if lighthouse_incremental?

    result = lighthouse_operation(operation)
    Lighthouse::GraphQL::CacheControl.apply(response, result)
    render json: result
  end

  # Does this request take a streamed response (Defer): the schema uses the
  # plugin, the controller includes ActionController::Live, and the client
  # accepts `multipart/mixed`?
  def lighthouse_incremental?
    defined?(::ActionController::Live) && is_a?(::ActionController::Live) &&
      !Lighthouse::GraphQL::Defer.stream_type_of(request).nil? && Lighthouse::GraphQL::Defer.enabled?(graphql_schema)
  end

  # Runs the operation as Incremental::Run does, and renders it whole when no
  # fragment is deferred, else streams the payloads as `multipart/mixed` parts
  # (not cacheable, whatever @cacheControl says).
  def lighthouse_incremental(operation)
    error = Lighthouse::GraphQL::PersistedQueries.incremental(graphql_schema, **lighthouse_arguments(operation)) do |run|
      lighthouse_answer(run)
      nil
    end
    render json: error if error
  end

  # A run that defers streams; one that does not is rendered, as the JSON path renders a result.
  def lighthouse_answer(run)
    return lighthouse_stream(run) if run.deferred?

    Lighthouse::GraphQL::CacheControl.apply(response, run.result)
    render json: run.result
  end

  # The payloads of `run`, one part each, written as they are ready.
  # A part encodes before it is written, so an error of the app's values is not taken for the
  # stream's. Until the first part is written, the response is not committed: an error then
  # surfaces as it would on the JSON path (`execute` does not close the stream).
  def lighthouse_stream(run)
    Lighthouse::GraphQL::Incremental::Multipart.headers(Lighthouse::GraphQL::Defer.stream_type_of(request)).each do |name, value|
      response.headers[name] = value
    end
    multipart = Lighthouse::GraphQL::Incremental::Multipart.new(response.stream)
    begin
      run.each_payload { |payload| lighthouse_write(multipart, multipart.part(payload)) }
    ensure
      lighthouse_write(multipart, nil) if multipart.started?
    end
  rescue Gone
    nil
  rescue StandardError => e
    lighthouse_report(e)
    raise
  end

  # Writes a part (or, without one, the closing boundary) to the response's stream: a client
  # that went away (ActionController::Live's ClientDisconnected, or the IOError of a closed
  # stream) ends the response quietly.
  def lighthouse_write(multipart, part)
    part ? multipart.emit(part) : multipart.finish
    @lighthouse_streaming = true
  rescue ::ActionController::Live::ClientDisconnected, ::IOError
    raise Gone
  end

  # An error raised once a streamed response is on its way: ActionController::Live only logs
  # it, so it goes to Rails.error too, where the JSON path's would go (the executor reports it).
  def lighthouse_report(error)
    ::Rails.error.report(error, handled: false) if defined?(::Rails) && ::Rails.respond_to?(:error) && response.committed?
  end

  # In development, an error that is not one Rails answers, before the response is on its way.
  def lighthouse_render_development_error?(error)
    defined?(::Rails) && ::Rails.env.development? && !rails_response?(error) && !response.committed?
  end

  # An error Rails answers with a status of its own (config.action_dispatch.rescue_responses):
  # ActionController::TooManyRequests from @throttle is a 429 in development too.
  def rails_response?(error)
    ::ActionDispatch::ExceptionWrapper.status_code_for_exception(error.class.name) != 500
  end

  def lighthouse_development_error(error)
    logger.error(error.message)
    logger.error(error.backtrace.join("\n"))

    render json: { errors: [{ message: error.message, backtrace: error.backtrace }], data: {} },
           status: :internal_server_error
  end
end
