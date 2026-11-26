require 'rails_helper'

# Lighthouse::GraphQL::Testing, PHP Lighthouse's MakesGraphQLRequests: requests to the app's
# endpoint from its tests.
RSpec.describe 'Lighthouse::GraphQL::Testing', type: :request do
  include Lighthouse::GraphQL::Testing

  before { create(:post, title: 'Hello') }

  it 'posts a query with its variables and answers the parsed body' do
    body = graphql('query($first: Int!) { posts(first: $first) { data { title } } }', { first: 1 })

    expect(body).to eq('data' => { 'posts' => { 'data' => [{ 'title' => 'Hello' }] } })
    expect(response).to have_http_status(:ok)
  end

  it 'posts extra parameters with the query, and a batch as it is' do
    named = graphql('query A { posts(first: 1) { data { title } } } query B { publishedPostCount }', extra_params: { operationName: 'B' })
    batch = post_graphql([{ query: '{ publishedPostCount }' }, { query: '{ posts(first: 1) { data { title } } }' }])

    expect(named).to eq('data' => { 'publishedPostCount' => 1 })
    expect(batch.map { |result| result['data'].keys }).to eq([%w[publishedPostCount], %w[posts]])
  end

  it 'posts a multipart request, with its files' do
    file = Rack::Test::UploadedFile.new(StringIO.new('png bytes'), 'image/png', original_filename: 'me.png')

    body = multipart_graphql({ query: '{ publishedPostCount }', variables: { file: nil } }, { '0' => ['variables.file'] }, { '0' => file })

    expect(body).to eq('data' => { 'publishedPostCount' => 1 })
  end

  it "introspects the schema, a type and a directive, and answers nil for one it doesn't have" do
    expect(introspect.dig('data', '__schema', 'queryType', 'name')).to eq('Query')
    expect(introspect_type('Post')['fields'].pluck('name')).to include('title', 'author')
    expect(introspect_directive('defer')['locations']).to eq(%w[FRAGMENT_SPREAD INLINE_FRAGMENT])
    expect([introspect_type('Nothing'), introspect_directive('nothing')]).to eq([nil, nil])
  end

  it 'answers the payloads of a streamed response, in either format' do
    query = '{ posts(first: 1) { data { title ... @defer { id } } } }'

    draft = stream_graphql(query)
    legacy = stream_graphql(query, headers: { 'Accept' => 'multipart/mixed;deferSpec=20220824' })

    expect(draft.pluck('hasNext')).to eq([true, false])
    expect(draft.last['completed']).to eq([{ 'id' => '0' }])
    expect(legacy.last['incremental'].first['path']).to eq(['posts', 'data', 0])
  end

  it 'raises when a response that was to stream comes whole' do
    expect { stream_graphql('{ publishedPostCount }') }
      .to raise_error(Lighthouse::GraphQL::Testing::NotStreamed, %r{got a regular one \(application/json; charset=utf-8\)})
  end
end
