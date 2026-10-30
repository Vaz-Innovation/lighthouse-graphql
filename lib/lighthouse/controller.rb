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
# When the schema uses Lighthouse::GraphQL::Defer, an operation that defers is
# streamed instead, as `multipart/mixed` parts (lighthouse_stream), unless the
# client's Accept header leaves them out: nothing else to set up, as PHP
# Lighthouse's DeferServiceProvider.
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
  def lighthouse_operation(operation = params, schema = graphql_schema)
    Lighthouse::GraphQL::PersistedQueries.execute(schema, **lighthouse_arguments(operation))
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

  # One operation: answered whole, or streamed (Defer) when it defers. The schema is resolved
  # once, for both.
  def lighthouse_respond(operation)
    schema = graphql_schema
    stream_type = lighthouse_stream_type(schema)
    return lighthouse_incremental(operation, schema, stream_type) if stream_type

    result = lighthouse_operation(operation, schema)
    Lighthouse::GraphQL::CacheControl.apply(response, result)
    render json: result
  end

  # The Content-Type of the response if it streams (Defer.stream_type), or nil when it comes
  # whole: the schema does not use the plugin, the client leaves `multipart/mixed` out, or the
  # request is a HEAD, whose response has no body.
  def lighthouse_stream_type(schema)
    return nil if request.head? || !Lighthouse::GraphQL::Defer.enabled?(schema)

    Lighthouse::GraphQL::Defer.stream_type(request.headers['Accept'])
  end

  # Runs the operation's first pass (Incremental::Run), and renders it whole when no fragment
  # is deferred (its operation ended), else streams it, in the format `stream_type` names.
  def lighthouse_incremental(operation, schema, stream_type)
    format = Lighthouse::GraphQL::Defer.legacy?(stream_type) ? :legacy : :draft
    run = Lighthouse::GraphQL::PersistedQueries.incremental(schema, format: format, **lighthouse_arguments(operation))
    return render json: run if run.is_a?(Hash)
    return lighthouse_stream(run, stream_type) if run.deferred?

    Lighthouse::GraphQL::CacheControl.apply(response, run.result)
    render json: run.result
  end

  # The response of a run that defers: its payloads as `multipart/mixed` parts (not cacheable,
  # whatever @cacheControl says), which Incremental::Body writes as the server sends the
  # response, after the action. The first part is encoded here, so that an error of the app's
  # values in it is answered as on the JSON path, nothing being sent: the operation then ends as
  # one that failed. The body ends the operation, then the request (EndRequest, with the parts
  # written as its response's body, kept only when something listens to it).
  def lighthouse_stream(run, stream_type)
    multipart = Lighthouse::GraphQL::Incremental::Multipart.new(keep: Lighthouse::Events.listening?(Lighthouse::Events::EndRequest))
    first = lighthouse_first_part(run, multipart)
    Lighthouse::GraphQL::Incremental::Multipart.headers(stream_type).each { |name, value| response.headers[name] = value }
    ended = -> { Lighthouse::Events.dispatch(Lighthouse::Events::EndRequest.new(multipart.ended(response))) }
    @lighthouse_body = Lighthouse::GraphQL::Incremental::Body.new(run, multipart, first, on_error: method(:lighthouse_report), on_end: ended)
    request.env['rack.response_finished']&.push(->(*) { @lighthouse_body.finish })
    self.response_body = @lighthouse_body
  end

  def lighthouse_first_part(run, multipart)
    multipart.part(run.first_payload)
  rescue StandardError
    run.refuse!
    run.finish
    raise
  end

  # A streamed body ends the request itself, once it is done (Incremental::Body).
  def lighthouse_streaming? = !@lighthouse_body.nil?

  # An error that ended a streamed response on its way, which Incremental::Body handled: to
  # Rails.error (where the JSON path's would go, through the executor or rescue_from), and the log.
  def lighthouse_report(error)
    lighthouse_log(error)
    ::Rails.error.report(error, handled: true, severity: :error) if defined?(::Rails) && ::Rails.respond_to?(:error)
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

  # An error, with its backtrace, to the log.
  def lighthouse_log(error) = logger&.error("#{error.class}: #{error.message}\n#{error.backtrace.to_a.join("\n")}")

  def lighthouse_development_error(error)
    lighthouse_log(error)

    render json: { errors: [{ message: error.message, backtrace: error.backtrace }], data: {} },
           status: :internal_server_error
  end
end
