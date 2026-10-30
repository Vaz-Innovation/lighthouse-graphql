# frozen_string_literal: true

require 'active_support/concern'
require 'active_support/core_ext/class/attribute'
require 'json'

# Run a GraphQL operation from any controller action, with the context the
# endpoint gives it: to render a page with its data already loaded, say.
# Lighthouse::GraphQL::Controller includes it, and adds the `execute` action.
#
#   class PagesController < ApplicationController
#     include Lighthouse::GraphQL::Operations
#
#     lighthouse_schema AppSchema
#
#     def home
#       @feed = lighthouse_execute('query Feed { posts(first: 10) { data { title } } }')
#       return if performed? # a @throttle answered 429
#     end
#   end
#
# `lighthouse_execute` runs the operation as the endpoint does
# (PersistedQueries.execute: the operation events, persisted queries), with
# `lighthouse_context`: `graphql_context` and what @throttle reads. The request
# events (StartRequest, EndRequest) are the endpoint's, one per GraphQL
# request, as PHP Lighthouse's GraphQLController dispatches them: wrap an
# action in `lighthouse_request { ... }` to dispatch them around it.
module Lighthouse::GraphQL::Operations
  extend ActiveSupport::Concern

  included do
    class_attribute :lighthouse_schema_source, instance_writer: false
  end

  class_methods do
    # The schema the operations run on: a schema class, its name (a String,
    # constantized per request so code reloading works) or a block (evaluated
    # in the controller, per request).
    def lighthouse_schema(schema = nil, &block)
      self.lighthouse_schema_source = schema || block
    end
  end

  private

  # The result of `query` (a Hash, as the endpoint renders it), or nil when a
  # @throttle `with:` method performed the response instead (`performed?`).
  # `context` adds to lighthouse_context; `extensions` takes a persisted
  # query's hash, as a client's request does (`query` nil).
  def lighthouse_execute(query, variables: {}, operation_name: nil, extensions: nil, context: {})
    Lighthouse::GraphQL::PersistedQueries.execute(
      graphql_schema,
      query: query, extensions: extensions, variables: graphql_variables(variables), operation_name: operation_name,
      context: lighthouse_context.merge(context)
    ).to_h
  rescue Lighthouse::GraphQL::Controller::Performed
    nil
  end

  # Dispatch StartRequest, run the block, dispatch EndRequest with the
  # response. Only the outermost call dispatches, and stops the block where a
  # @throttle `with:` method performed the response.
  def lighthouse_request
    return yield if @lighthouse_request_started

    @lighthouse_request_started = true
    Lighthouse::Events.dispatch(Lighthouse::Events::StartRequest.new(request))
    result = begin
      yield
    rescue Lighthouse::GraphQL::Controller::Performed
      nil
    end
    Lighthouse::Events.dispatch(Lighthouse::Events::EndRequest.new(lighthouse_response))
    result
  end

  # The response EndRequest carries (the controller's streamed one is closed first).
  def lighthouse_response = response

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
end
