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
# `{}`), `graphql_schema` and `graphql_variables(param)`. A controller with an
# action of its own wraps it in `lighthouse_request { ... }` to get the request
# events; a nested call dispatches them once.
module Lighthouse::GraphQL::Controller
  extend ActiveSupport::Concern

  # Raised once a @throttle `with:` method has performed the response: control
  # flow, as `throw :abort` in a before_action, so no `rescue StandardError` (a
  # schema's rescue_from) catches it on its way out of the operation.
  class Performed < Exception; end # rubocop:disable Lint/InheritException

  included do
    class_attribute :lighthouse_schema_source, instance_writer: false
  end

  class_methods do
    # The schema `execute` runs: a schema class, its name (a String, constantized
    # per request so code reloading works) or a block (evaluated in the
    # controller, per request).
    def lighthouse_schema(schema = nil, &block)
      self.lighthouse_schema_source = schema || block
    end
  end

  def execute
    lighthouse_request do
      operations = lighthouse_operations
      if operations.is_a?(Array)
        render json: lighthouse_batch(operations.map { |operation| lighthouse_hash(operation) })
      else
        result = lighthouse_operation(operations)
        Lighthouse::GraphQL::CacheControl.apply(response, result)
        render json: result
      end
    end
  rescue StandardError => e
    raise e unless defined?(::Rails) && ::Rails.env.development? && !rails_response?(e)

    lighthouse_development_error(e)
  end

  private

  # Dispatch StartRequest, run the block, dispatch EndRequest with the
  # response. Only the outermost call dispatches, and stops the block where a
  # @throttle `with:` method performed the response.
  def lighthouse_request
    return yield if @lighthouse_request_started

    @lighthouse_request_started = true
    Lighthouse::Events.dispatch(Lighthouse::Events::StartRequest.new(request))
    result = begin
      yield
    rescue Performed
      nil
    end
    Lighthouse::Events.dispatch(Lighthouse::Events::EndRequest.new(response))
    result
  end

  # The context of the operation: what @guard and the @can* directives read.
  def graphql_context
    respond_to?(:current_user, true) ? { current_user: current_user } : {}
  end

  # graphql_context, with what @throttle reads unless it sets its own: the
  # client's IP (rate_limit's default by:) and the controller, whose cache_store,
  # controller_path and methods rate_limit uses.
  def lighthouse_context
    { remote_ip: request.remote_ip, lighthouse_controller: self }.merge(graphql_context)
  end

  def graphql_schema
    source = lighthouse_schema_source
    case source
    when nil then raise Lighthouse::DefinitionError, "#{self.class}: name the schema with `lighthouse_schema AppSchema`"
    when String, Symbol then source.to_s.constantize
    when Proc then instance_exec(&source)
    else source
    end
  end

  # Variables arrive as a JSON string (GET or form posts) or as parameters.
  def graphql_variables(param)
    case param
    when String then param.present? ? JSON.parse(param) || {} : {}
    when Hash then param
    when nil then {}
    else
      raise ArgumentError, "Unexpected parameter: #{param}" unless param.respond_to?(:to_unsafe_h)

      param.to_unsafe_h
    end
  end

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
    operation = operation.with_indifferent_access if operation.is_a?(Hash)
    Lighthouse::GraphQL::PersistedQueries.execute(
      graphql_schema,
      query: operation[:query], extensions: operation[:extensions],
      variables: graphql_variables(operation[:variables]), operation_name: operation[:operationName], context: lighthouse_context
    )
  end

  # Each operation gets its own context: `schema.multiplex`'s `context:` is the
  # multiplex's, which the queries' resolvers never see.
  def lighthouse_batch(operations)
    operations = operations.map do |operation|
      { query: operation[:query], extensions: operation[:extensions], variables: graphql_variables(operation[:variables]),
        operation_name: operation[:operationName], context: lighthouse_context }
    end
    Lighthouse::GraphQL::PersistedQueries.multiplex(graphql_schema, operations)
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
