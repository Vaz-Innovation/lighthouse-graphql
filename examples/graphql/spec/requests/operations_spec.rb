require 'rails_helper'

# lighthouse_execute: an operation run from an action of the app's own, with
# the context the GraphQL endpoint gives it.
RSpec.describe 'Operations outside the GraphQL endpoint', type: :request do
  let(:user) { create(:user, name: 'Ada') }

  def search(ip: '10.9.0.1', as: nil)
    get '/search', params: { term: 'x' }, headers: auth_headers(as), env: { 'REMOTE_ADDR' => ip }
    response.parsed_body
  end

  it "runs the operation with the endpoint's context: the signed-in user" do
    expect(search(as: user)).to eq('preloaded' => { 'data' => { 'searchPosts' => [], 'me' => { 'name' => 'Ada' } } })
    expect(search.dig('preloaded', 'errors', 0, 'message')).to eq('Unauthenticated.')
  end

  it 'counts @throttle where the endpoint counts it, and leaves the action the 429 it answered' do
    10.times { search(ip: '10.9.0.2', as: user) }
    search(ip: '10.9.0.2', as: user)

    expect(response).to have_http_status(:too_many_requests)
    expect(Rails.cache.read('rate-limit:pages:Query.searchPosts:10.9.0.2', raw: true).to_i).to eq(11)
  end
end
