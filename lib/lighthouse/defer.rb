# frozen_string_literal: true

# @defer and @stream: the fields of a fragment, and the items of a list, arrive after the rest of the response
# (experimental: the specification it follows is still a draft, see
# docs/performance.md). A graphql-ruby plugin, opted into in the schema class:
#
#   class AppSchema < Lighthouse::GraphQL::RbLightHouse.get_schema(...)
#     use GraphQL::Dataloader
#     use Lighthouse::GraphQL::Defer
#   end
#
#   class GraphqlStreamingController < GraphqlController
#     include ActionController::Live        # only the streamed requests run in it
#   end
#
#   # config/routes.rb: the client that prefers multipart/mixed goes to the streaming one
#   post '/graphql', to: 'graphql_streaming#execute', constraints: Lighthouse::GraphQL::Defer::Streaming
#   post '/graphql', to: 'graphql#execute'
#
# The plugin adds the directives to the schema (without it the schema has none,
# as the specification asks of a server that does not implement it). A
# controller streams a response when the schema uses the plugin, the controller
# includes ActionController::Live, and the client prefers `multipart/mixed`
# (`Defer.stream_type`); every other request is answered whole. The plugin also
# installs Rules, the analyzer that checks the directives in every query.
# Run does the work; Document, State, Serializer and Multipart are its parts.
module Lighthouse::GraphQL::Defer
  MULTIPART = 'multipart/mixed'
  # The Accept parameter of Apollo Client's older format, which this is not.
  OLD_FORMAT = 'deferspec'
  # What a client names when it reads the specification draft's format.
  FORMAT = 'incrementalspec=v0.2'
  JSON_TYPES = %w[application/json application/graphql-response+json].freeze

  # A media range of an Accept header; `rank` orders them as preferred first.
  MediaRange = Struct.new(:type, :params, :q, :index) do
    def rank = [-q, index]

    # multipart/mixed, but in the older format.
    def streams? = type == MULTIPART && params.none? { |param| param.start_with?(OLD_FORMAT) }
    def json? = JSON_TYPES.include?(type)
    def before?(other) = other.nil? || (rank <=> other.rank).negative?
  end

  module_function

  # graphql-ruby's plugin hook: `use Lighthouse::GraphQL::Defer`.
  def use(schema, **_options)
    unless defined?(::GraphQL::Query::Partial) && ::GraphQL::Query::Partial.instance_method(:initialize).parameters.include?(%i[key fragment_node])
      raise Lighthouse::DefinitionError, 'Lighthouse::GraphQL::Defer needs graphql-ruby 2.5.21 or newer (GraphQL::Query::Partial#fragment_node).'
    end

    schema.directive(Lighthouse::GraphQL::Incremental::DeferDirective)
    schema.directive(Lighthouse::GraphQL::Incremental::StreamDirective)
    schema.query_analyzer(Lighthouse::GraphQL::Incremental::Rules)
    schema.trace_with(Lighthouse::GraphQL::Incremental::StreamTrace)
  end

  # Where a request's stream_type is kept, so the header is read once.
  ENV_KEY = 'lighthouse.defer.stream_type'

  # A route constraint: does the request prefer a streamed response? It keeps the answer in
  # the request for the controller.
  module Streaming
    def self.matches?(request) = !Lighthouse::GraphQL::Defer.stream_type_of(request).nil?
  end

  # The request's stream_type, its `Accept` header read once.
  def stream_type_of(request)
    request.env.fetch(ENV_KEY) { request.env[ENV_KEY] = stream_type(request.headers['Accept']) }
  end

  def enabled?(schema)
    schema.directives['defer'] == Lighthouse::GraphQL::Incremental::DeferDirective
  end

  # The Content-Type of the streamed response to `accept`, or nil when the client does not prefer
  # one in this gem's format to JSON. It names the format when the client did.
  def stream_type(accept)
    range = preferred(accept) or return nil
    type = Lighthouse::GraphQL::Incremental::Multipart::CONTENT_TYPE
    range.params.include?(FORMAT) ? "#{type}; incrementalSpec=v0.2" : type
  end

  # The `multipart/mixed` range of the header the client prefers to a JSON response, if one:
  # not at q=0, not in the older format, and ranked (q, then order, as Rails ranks them) no
  # lower than application/json or application/graphql-response+json. Rails' Mime::Type.parse
  # ranks the types, but drops their parameters (the format is one), so this reads them.
  def preferred(accept)
    ranges = ranges(accept).select { |range| range.q.positive? }
    multipart = best(ranges, &:streams?)
    multipart if multipart&.before?(best(ranges, &:json?))
  end

  # The preferred of the ranges the block selects.
  def best(ranges, &block)
    ranges.select(&block).min_by(&:rank)
  end

  # Each media range of the header: its type, its parameters (lowercase, but q) and its q.
  def ranges(accept)
    accept.to_s.split(',').each_with_index.map do |range, index|
      type, *params = range.split(';').map { |part| part.strip.downcase }
      q = params.find { |param| param.start_with?('q=') }
      MediaRange.new(type, params - [q], q ? q.delete_prefix('q=').to_f : 1.0, index)
    end
  end
end
