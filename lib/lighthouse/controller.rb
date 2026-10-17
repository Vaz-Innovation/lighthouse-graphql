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
# PersistedQueries.multiplex for a batch, a JSON array body), sets the
# Cache-Control header the selected fields' @cacheControl hints allow, renders
# the JSON and dispatches EndRequest. In development an error renders as JSON.
#
# Hooks, private so they are not actions: `graphql_context` (default:
# `{ current_user: current_user }` when the controller has a current_user, else
# `{}`), `graphql_schema` and `graphql_variables(param)`. A controller with an
# action of its own wraps it in `lighthouse_request { ... }` to get the request
# events; a nested call dispatches them once.
module Lighthouse::GraphQL::Controller
  extend ActiveSupport::Concern

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
      batch = params[:_json]
      if batch.is_a?(Array)
        render json: lighthouse_batch(batch)
      else
        result = lighthouse_operation
        Lighthouse::GraphQL::CacheControl.apply(response, result)
        render json: result
      end
    end
  rescue StandardError => e
    raise e unless defined?(::Rails) && ::Rails.env.development?

    lighthouse_development_error(e)
  end

  private

  # Dispatch StartRequest, run the block, dispatch EndRequest with the
  # response. Only the outermost call dispatches.
  def lighthouse_request
    return yield if @lighthouse_request_started

    @lighthouse_request_started = true
    Lighthouse::Events.dispatch(Lighthouse::Events::StartRequest.new(request))
    result = yield
    Lighthouse::Events.dispatch(Lighthouse::Events::EndRequest.new(response))
    result
  end

  # The context of the operation: what @guard and the @can* directives read.
  def graphql_context
    respond_to?(:current_user, true) ? { current_user: current_user } : {}
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

  def lighthouse_operation
    Lighthouse::GraphQL::PersistedQueries.execute(
      graphql_schema,
      query: params[:query], extensions: params[:extensions],
      variables: graphql_variables(params[:variables]), operation_name: params[:operationName], context: graphql_context
    )
  end

  # Each operation gets its own context: `schema.multiplex`'s `context:` is the
  # multiplex's, which the queries' resolvers never see.
  def lighthouse_batch(operations)
    operations = operations.map do |operation|
      { query: operation[:query], extensions: operation[:extensions], variables: graphql_variables(operation[:variables]),
        operation_name: operation[:operationName], context: graphql_context }
    end
    Lighthouse::GraphQL::PersistedQueries.multiplex(graphql_schema, operations)
  end

  def lighthouse_development_error(error)
    logger.error(error.message)
    logger.error(error.backtrace.join("\n"))

    render json: { errors: [{ message: error.message, backtrace: error.backtrace }], data: {} },
           status: :internal_server_error
  end
end
