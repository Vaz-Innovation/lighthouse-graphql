# frozen_string_literal: true

require 'json'

# Requests to the app's GraphQL endpoint, for its tests: PHP Lighthouse's MakesGraphQLRequests.
# Include it where Rails' integration session runs (an RSpec request spec, an
# ActionDispatch::IntegrationTest):
#
#   RSpec.configure { |config| config.include Lighthouse::GraphQL::Testing, type: :request }
#
#   it 'lists the posts' do
#     body = graphql('{ posts(first: 1) { data { title } } }')
#     expect(body.dig('data', 'posts', 'data')).to eq([{ 'title' => 'Hello' }])
#   end
#
# Each request answers the response's parsed JSON body (`response` holds the response itself, as
# after any request). The endpoint is `graphql_endpoint`, `/graphql` unless a test overrides it.
module Lighthouse::GraphQL::Testing
  # A request that was to stream did not.
  class NotStreamed < StandardError; end

  # POSTs a query with its variables (and `extra_params`, `operationName` or `extensions`), as JSON.
  def graphql(query, variables = {}, extra_params: {}, headers: {})
    post_graphql(graphql_operation(query, variables, extra_params), headers: headers)
  end

  # POSTs `data` as JSON: an operation's Hash, or a batch's Array of them.
  def post_graphql(data, headers: {})
    post_graphql_json(data, headers)
    response.parsed_body
  end

  # POSTs a multipart request (graphql-multipart-request-spec, MultipartRequest): `operations`,
  # the `map` from each file's key to the variables it fills, and the files by key
  # (Rack::Test::UploadedFile).
  def multipart_graphql(operations, map, files, headers: {})
    params = { 'operations' => operations.to_json, 'map' => map.to_json }.merge(files.transform_keys(&:to_s))
    post graphql_endpoint, params: params, headers: headers
    response.parsed_body
  end

  # The response to graphql-ruby's introspection query.
  def introspect = graphql(::GraphQL::Introspection.query)

  # The introspection of the type, or of the directive, named `name`; nil when the schema has none.
  def introspect_type(name) = introspect_by_name('types', name)
  def introspect_directive(name) = introspect_by_name('directives', name)

  # POSTs a query whose response streams (@defer, @stream), and answers each of its payloads,
  # in order: the first, then one per round. `Accept` is `multipart/mixed` unless the headers say
  # otherwise (Apollo's older format: `multipart/mixed;deferSpec=20220824`). A response that did
  # not stream (the query deferred nothing, or the schema does not use Lighthouse::GraphQL::Defer)
  # raises NotStreamed.
  def stream_graphql(query, variables = {}, extra_params: {}, headers: {})
    post_graphql_json(graphql_operation(query, variables, extra_params), { 'Accept' => 'multipart/mixed' }.merge(headers))
    unless response.content_type.to_s.split(';').first == Lighthouse::GraphQL::Defer::MULTIPART
      raise NotStreamed, "Expected a streamed response, got a regular one (#{response.content_type})."
    end

    Lighthouse::GraphQL::Incremental::Multipart.parse(response.body)
  end

  # The endpoint's path.
  def graphql_endpoint = '/graphql'

  private

  def graphql_operation(query, variables, extra_params)
    operation = { query: query }
    operation[:variables] = variables unless variables.empty?
    operation.merge(extra_params)
  end

  def post_graphql_json(data, headers)
    post graphql_endpoint, params: data.to_json, headers: { 'Content-Type' => 'application/json' }.merge(headers)
  end

  def introspect_by_name(path, name)
    introspect.dig('data', '__schema', path)&.find { |entry| entry['name'] == name }
  end
end
