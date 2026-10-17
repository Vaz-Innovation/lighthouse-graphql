require 'rails_helper'

RSpec.describe 'GraphiQL', type: :request do
  context 'when in development' do
    before { allow(Rails).to receive(:env).and_return(ActiveSupport::EnvironmentInquirer.new('development')) }

    it 'serves the IDE, pointed at the app endpoint' do
      get '/graphiql'

      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq('text/html')
      expect(response.body).to include('graphiql.min.js', 'createFetcher({ url: "/graphql" })', 'query LatestPosts')
    end
  end

  it 'is not routed in any other environment' do
    get '/graphiql'

    expect(response).to have_http_status(:not_found)
  end
end
