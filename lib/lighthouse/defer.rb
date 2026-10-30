# frozen_string_literal: true

# @defer: the fields of a fragment arrive after the rest of the response
# (experimental: the specification it follows is still a draft, see
# docs/performance.md). A graphql-ruby plugin, opted into in the schema class:
#
#   class AppSchema < Lighthouse::GraphQL::RbLightHouse.get_schema(...)
#     use GraphQL::Dataloader
#     use Lighthouse::GraphQL::Defer
#   end
#
#   class GraphqlController < ApplicationController
#     include ActionController::Live        # streams the response
#     include Lighthouse::GraphQL::Controller
#     lighthouse_schema AppSchema
#   end
#
# The plugin adds the directive to the schema (without it the schema has none,
# as the specification asks of a server that does not implement it). The
# controller streams a response when the schema uses the plugin, the controller
# includes ActionController::Live, and the client accepts `multipart/mixed`
# (`Defer.accepts?`); every other request is answered whole, with @defer ignored.
# Run does the work; Document, State, Serializer and Multipart are its parts.
module Lighthouse::GraphQL::Defer
  MULTIPART = 'multipart/mixed'
  # The Accept parameter of Apollo Client's older format, which this is not.
  OLD_FORMAT = 'deferspec'
  # What a client names when it reads the specification draft's format.
  FORMAT = 'incrementalspec=v0.2'

  module_function

  # graphql-ruby's plugin hook: `use Lighthouse::GraphQL::Defer`.
  def use(schema, **_options)
    unless defined?(::GraphQL::Query::Partial) && ::GraphQL::Query::Partial.instance_method(:initialize).parameters.include?(%i[key fragment_node])
      raise Lighthouse::DefinitionError, 'Lighthouse::GraphQL::Defer needs graphql-ruby 2.5.21 or newer (GraphQL::Query::Partial#fragment_node).'
    end

    schema.directive(Lighthouse::GraphQL::Incremental::DeferDirective)
  end

  def enabled?(schema)
    schema.directives['defer'] == Lighthouse::GraphQL::Incremental::DeferDirective
  end

  # Does the `Accept` header take a streamed response in this gem's format?
  def accepts?(accept)
    ranges(accept).any?
  end

  # The Content-Type of the streamed response to `accept`: it names the format when the client did.
  def content_type(accept)
    named = ranges(accept).any? { |params| params.include?(FORMAT) }
    named ? "#{Lighthouse::GraphQL::Incremental::Multipart::CONTENT_TYPE}; incrementalSpec=v0.2" : Lighthouse::GraphQL::Incremental::Multipart::CONTENT_TYPE
  end

  # The parameters of each `multipart/mixed` range of the header, but those of the older format.
  def ranges(accept)
    accept.to_s.split(',').filter_map do |range|
      type, *params = range.split(';').map { |part| part.strip.downcase }
      params if type == MULTIPART && params.none? { |param| param.start_with?(OLD_FORMAT) }
    end
  end
end
