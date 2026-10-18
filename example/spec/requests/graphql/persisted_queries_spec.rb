require 'rails_helper'

# Apollo's Automatic Persisted Queries, as Apollo Client's createPersistedQueryLink speaks them.
RSpec.describe 'GraphQL persisted queries', type: :request do
  let(:query) { '{ posts { data { title } } }' }
  let(:extensions) { { persistedQuery: { version: 1, sha256Hash: Digest::SHA256.hexdigest(query) } } }

  before { create(:post, title: 'Persisted') }

  it 'asks for the query once, then runs it by hash alone' do
    expect(graphql(extensions: extensions).dig('errors', 0, 'extensions', 'code')).to eq('PERSISTED_QUERY_NOT_FOUND')
    expect(graphql(query, extensions: extensions).dig('data', 'posts', 'data')).to eq([{ 'title' => 'Persisted' }])
    expect(graphql(extensions: extensions).dig('data', 'posts', 'data')).to eq([{ 'title' => 'Persisted' }])
  end

  it 'serves registered queries over GET, so a CDN can cache them' do
    graphql(query, extensions: extensions)

    get '/graphql', params: { extensions: extensions.to_json }

    expect(response.parsed_body.dig('data', 'posts', 'data')).to eq([{ 'title' => 'Persisted' }])
    expect(response.headers['Cache-Control']).to eq('max-age=60, public')
    expect(response.headers['ETag']).to be_present
  end

  it 'serves the trusted operations of persisted-queries.json by hash, with nothing registered' do
    manifest = JSON.parse(Rails.root.join('persisted-queries.json').read)
    tags = manifest['operations'].find { |operation| operation['name'] == 'Tags' }
    create(:tag, name: 'ruby')

    body = graphql(extensions: { persistedQuery: { version: 1, sha256Hash: tags['id'] } })

    expect(body).to eq('data' => { 'tags' => [{ 'id' => Base64.strict_encode64("Tag:#{Tag.last.id}"), 'name' => 'ruby' }] })
  end

  it 'refuses a query that does not match its hash' do
    body = graphql('{ tags { name } }', extensions: extensions)

    expect(error_messages(body)).to eq(['provided sha does not match query'])
  end
end
