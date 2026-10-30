require 'rails_helper'

# Only a streamed request runs in ActionController::Live: GraphqlStreamingController, which a route
# picks for a client that prefers multipart/mixed (Lighthouse::GraphQL::Defer::Streaming). The plain
# endpoint is unchanged, and answers any client whole.
RSpec.describe GraphqlController, type: :controller do
  it 'runs outside ActionController::Live, where GraphqlStreamingController runs in it' do
    expect(described_class.ancestors).not_to include(ActionController::Live)
    expect(GraphqlStreamingController.ancestors).to include(ActionController::Live)
  end

  it 'answers a client that prefers multipart/mixed with one ordinary response' do
    create(:post, title: 'Hello')
    request.headers['Accept'] = 'multipart/mixed;incrementalSpec=v0.2, application/json'

    post :execute, params: { query: '{ posts(first: 1) { data { title ... @defer { id } } } }' }

    expect(response.media_type).to eq('application/json')
    expect(response.parsed_body.dig('data', 'posts', 'data', 0).keys).to eq(%w[title id])
  end
end
