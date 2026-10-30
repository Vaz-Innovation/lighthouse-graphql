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
# (`Defer.stream_type_of(request)`); every other request is answered whole. The plugin also
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

  # The oldest graphql-ruby it runs on: GraphQL::Query::Partial#fragment_node (2.5.21), and a
  # runtime that gives each list item run in a Dataloader job its own path (2.5.23), which the
  # paths of the fragments and objects it keeps are read from (context[:current_path]).
  GRAPHQL = '2.5.23'

  # graphql-ruby's plugin hook: `use Lighthouse::GraphQL::Defer`.
  def use(schema, **_options)
    if Gem::Version.new(::GraphQL::VERSION) < Gem::Version.new(GRAPHQL)
      raise Lighthouse::DefinitionError, "Lighthouse::GraphQL::Defer needs graphql-ruby #{GRAPHQL} or newer."
    end

    schema.directive(Lighthouse::GraphQL::Incremental::DeferDirective)
    schema.directive(Lighthouse::GraphQL::Incremental::StreamDirective)
    schema.query_analyzer(Lighthouse::GraphQL::Incremental::Rules)
    schema.trace_with(Lighthouse::GraphQL::Incremental::StreamTrace)
    schema.extend(Used)
  end

  # What a schema class that uses the plugin is extended with, which its subclasses inherit.
  module Used; end

  # Where a request's stream_type is kept, so the header is read once.
  ENV_KEY = 'lighthouse.defer.stream_type'

  # A route constraint: can the request stream, and does it prefer to? One operation (not a
  # batch, a JSON array body; not a multipart upload, `multipart/form-data`), from a client whose
  # Accept header prefers a streamed response. It keeps that answer in the request for the
  # controller. A JSON body is read as Rails reads it for the parameters (Request#raw_post, once).
  module Streaming
    def self.matches?(request)
      return false if Lighthouse::GraphQL::Defer.stream_type_of(request).nil? || request.media_type == 'multipart/form-data'

      !(request.media_type.to_s.end_with?('json') && request.raw_post.to_s.lstrip.start_with?('['))
    end
  end

  # The request's stream_type, its `Accept` header read once.
  def stream_type_of(request)
    request.env.fetch(ENV_KEY) { request.env[ENV_KEY] = stream_type(request.headers['Accept']) }
  end

  # Does `schema` use the plugin? Decided once a schema class (Schema.directives builds a Hash on
  # every call), as `use` marks it.
  def enabled?(schema) = schema.is_a?(Used)

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
