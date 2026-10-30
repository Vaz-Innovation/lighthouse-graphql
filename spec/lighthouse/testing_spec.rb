# frozen_string_literal: true

require 'spec_helper'

# Lighthouse::GraphQL::Testing on a session that answers what the endpoint would: the example
# app's spec/requests/graphql/testing_spec.rb runs it on Rails' own.
RSpec.describe 'Lighthouse::GraphQL::Testing' do
  let(:schema) do
    build_schema('type Query { greeting(name: String): String @field(resolver: "TestingSpecGreeting@call") }').tap { |s| s.use(Lighthouse::GraphQL::Defer) }
  end
  let(:session) do
    schema = self.schema
    Class.new do
      include Lighthouse::GraphQL::Testing

      attr_reader :posts, :response

      define_method(:schema) { schema }

      def initialize = @posts = []

      def post(path, params:, headers: {})
        @posts << [path, params, headers]
        operation = params.is_a?(String) ? JSON.parse(params) : params
        result = schema.execute(operation['query'], variables: operation['variables'] || {}).to_h
        streamed = operation['query'].to_s.include?('@defer') && headers['Accept'] != 'application/json'
        part = "\r\n---\r\nContent-Type: application/json\r\n\r\n#{result.to_json}\r\n-----\r\n"
        @response = TestingSpecResponse.new(streamed ? part : result.to_json,
                                            streamed ? 'multipart/mixed; boundary="-"' : 'application/json; charset=utf-8')
      end
    end.new
  end

  it 'posts a query, its variables and extra parameters as JSON to /graphql, and answers the parsed body' do
    body = session.graphql('query($name: String) { greeting(name: $name) }', { name: 'Ana' }, extra_params: { operationName: nil })
    path, params, headers = session.posts.last

    expect(body).to eq('data' => { 'greeting' => 'Hello, Ana' })
    expect(path).to eq('/graphql')
    expect(JSON.parse(params)).to eq('query' => 'query($name: String) { greeting(name: $name) }', 'variables' => { 'name' => 'Ana' },
                                     'operationName' => nil)
    expect(headers).to eq('Content-Type' => 'application/json')
  end

  it 'leaves the variables out when there are none' do
    session.graphql('{ greeting }')

    expect(JSON.parse(session.posts.last[1])).to eq('query' => '{ greeting }')
  end

  it 'introspects a type and a directive, nil for one the schema does not have' do
    expect(session.introspect_type('Query')['fields'].pluck('name')).to eq(['greeting'])
    expect(session.introspect_directive('skip')['locations']).to include('FIELD')
    expect(session.introspect_type('Nothing')).to be_nil
  end

  it 'answers the payloads of a streamed response, and raises for one that came whole' do
    expect(session.stream_graphql('{ ... @defer { greeting } }')).to eq([{ 'data' => { 'greeting' => 'Hello, you' } }])
    expect(session.posts.last[2]).to eq('Content-Type' => 'application/json', 'Accept' => 'multipart/mixed')
    expect { session.stream_graphql('{ greeting }') }
      .to raise_error(Lighthouse::GraphQL::Testing::NotStreamed, 'Expected a streamed response, got a regular one (application/json; charset=utf-8).')
  end
end

class TestingSpecGreeting
  def self.call(_obj, args, _ctx) = "Hello, #{args[:name] || 'you'}"
end

TestingSpecResponse = Struct.new(:body, :content_type) do
  def parsed_body = JSON.parse(body)
end
