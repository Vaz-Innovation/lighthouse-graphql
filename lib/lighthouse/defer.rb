# frozen_string_literal: true

# @defer and @stream: the fields of a fragment, and the items of a list, arrive after the rest of the response
# (experimental: the specification it follows is still a draft, see docs/defer.md). A graphql-ruby
# plugin, opted into in the schema class, as PHP Lighthouse's DeferServiceProvider is registered:
#
#   class AppSchema < Lighthouse::GraphQL::RbLightHouse.get_schema(...)
#     use GraphQL::Dataloader
#     use Lighthouse::GraphQL::Defer
#   end
#
# The plugin adds the directives to the schema (without it the schema has none, as the
# specification asks of a server that does not implement it), and installs Rules, the analyzer
# that checks them in every query. Lighthouse::GraphQL::Controller then streams the response of
# an operation that defers, as PHP Lighthouse does, unless the client's Accept header leaves out
# `multipart/mixed` (`Defer.stream_type`), in the format the client reads: the specification
# draft's, or Apollo's older one (`deferSpec=20220824`). Every other response comes whole.
# Run does the work; Document, State, Serializer, Legacy, Multipart and Body are its parts.
module Lighthouse::GraphQL::Defer
  MULTIPART = 'multipart/mixed'
  # The Accept parameter of Apollo's older format (Incremental::Legacy), and the Content-Type's.
  LEGACY = 'deferspec'
  LEGACY_TYPE = 'deferSpec=20220824'
  # What a client names when it reads the specification draft's format.
  FORMAT = 'incrementalspec=v0.2'

  # A media range of an Accept header; `rank` orders them as preferred first.
  MediaRange = Struct.new(:type, :params, :q, :index) do
    def rank = [-q, index]

    # Does the range cover the media type `name` (itself, its `type/*`, or `*/*`)?
    def covers?(name) = type == name || type == '*/*' || (type.end_with?('/*') && name.start_with?(type.delete_suffix('*')))

    # How specific the range is: a type, then `type/*`, then `*/*`.
    def specificity = (type == '*/*' ? 0 : 1) + (type.end_with?('/*') ? 0 : 1)

    # Does it name Apollo's older format?
    def legacy? = params.any? { |param| param.start_with?(LEGACY) }
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

  # Does `schema` use the plugin? Decided once a schema class (Schema.directives builds a Hash on
  # every call), as `use` marks it.
  def enabled?(schema) = schema.is_a?(Used)

  # The Content-Type of a streamed response to a client that sends `accept`, or nil when the
  # client does not take one. As PHP Lighthouse, which streams whatever the client accepts, it is
  # streamed to any client but one whose header leaves `multipart/mixed` out: no range covers
  # it, or the most specific that does is at q=0 (`application/json` alone). The format is the
  # specification draft's, or Apollo's older one when the client's preferred `multipart/mixed`
  # range names it (`deferSpec=20220824`); the Content-Type names the format the client named.
  def stream_type(accept)
    type = Lighthouse::GraphQL::Incremental::Multipart::CONTENT_TYPE
    return type if accept.to_s.strip.empty?

    ranges = ranges(accept)
    named = ranges.select { |range| range.type == MULTIPART }
    return wildcard(type, ranges) if named.empty?

    preferred = named.select { |range| range.q.positive? }.min_by(&:rank)
    content_type(type, preferred) if preferred
  end

  # A header that names no multipart/mixed range: the most specific range that covers it decides.
  def wildcard(type, ranges)
    covering = ranges.select { |range| range.covers?(MULTIPART) }.max_by { |range| [range.specificity, range.q] }
    type if covering&.q&.positive?
  end

  # Is `content_type` (stream_type's) Apollo's older format?
  def legacy?(content_type) = content_type.to_s.include?(LEGACY_TYPE)

  def content_type(type, range)
    return "#{type}; #{LEGACY_TYPE}" if range.legacy?

    range.params.include?(FORMAT) ? "#{type}; incrementalSpec=v0.2" : type
  end

  # Each media range of the header: its type, its parameters (lowercase, but q) and its q.
  # A range that is empty or not a media type (`type/subtype`) is skipped.
  def ranges(accept)
    accept.to_s.split(',').each_with_index.filter_map do |range, index|
      type, *params = range.split(';').map { |part| part.strip.downcase }
      next unless type&.match?(%r{\A[^/\s]+/[^/\s]+\z})

      q = params.find { |param| param.start_with?('q=') }
      MediaRange.new(type, params - [q], q ? q.delete_prefix('q=').to_f : 1.0, index)
    end
  end

  private_class_method :content_type, :wildcard
end
