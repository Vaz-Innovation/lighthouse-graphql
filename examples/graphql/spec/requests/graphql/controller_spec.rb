require 'rails_helper'

# Lighthouse::GraphQL::Controller, as GraphqlController includes it.
RSpec.describe 'GraphQL controller concern', type: :request do
  let(:events) { [] }

  before do
    create(:post, title: 'Hello')
    Lighthouse::Events.listen(Lighthouse::Events::StartRequest) { |event| (events << [:start, event.request.path]) && nil }
    Lighthouse::Events.listen(Lighthouse::Events::EndRequest) { |event| (events << [:end, event.response.status]) && nil }
  end

  after { Lighthouse::Events.reset! }

  it 'dispatches StartRequest and EndRequest once each, around the operation' do
    Lighthouse::Events.listen(Lighthouse::Events::StartExecution) { (events << [:execution]) && nil }

    graphql('{ posts { data { title } } }')

    expect(events).to eq([[:start, '/graphql'], [:execution], [:end, 200]])
  end

  it 'reads variables sent as a JSON string, as a GET carries them' do
    get '/graphql', params: { query: 'query($n: Int) { posts(first: $n) { data { title } } }', variables: { n: 1 }.to_json }

    expect(response.parsed_body.dig('data', 'posts', 'data')).to eq([{ 'title' => 'Hello' }])
  end

  it 'reads variables sent as JSON' do
    body = graphql('query($id: ID!) { post(id: $id) { title } }', variables: { id: Post.last.id })

    expect(body.dig('data', 'post', 'title')).to eq('Hello')
  end

  it 'takes the context from the current user' do
    user = create(:user)

    expect(graphql('{ me { name } }', as: user).dig('data', 'me', 'name')).to eq(user.name)
    expect(error_messages(graphql('{ me { name } }'))).not_to be_empty
  end

  it 'sets the Cache-Control header of the selected fields' do
    graphql('{ posts { data { title } } }')

    expect(response.headers['Cache-Control']).to eq('max-age=60, public')
  end

  it 'runs a batch, one result per operation' do
    post '/graphql', params: [{ query: '{ posts { data { title } } }' }, { query: '{ tags { name } }' }], as: :json

    expect(response.parsed_body.map { |result| result['data'].keys }).to eq([['posts'], ['tags']])
    expect(events.map(&:first)).to eq(%i[start end])
  end

  it 'gives every operation of a batch the context' do
    user = create(:user)

    post '/graphql', params: [{ query: '{ me { name } }' }, { query: '{ me { name } }' }], headers: auth_headers(user), as: :json

    expect(response.parsed_body.map { |result| result.dig('data', 'me', 'name') }).to eq([user.name, user.name])
  end
end
