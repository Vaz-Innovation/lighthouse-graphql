require 'rails_helper'

# @throttle is Rails' rate_limit on one field: it counts where, and as, the
# controller's own rate_limit counts, beside it.
RSpec.describe 'GraphQL @throttle', type: :request do
  let(:user) { create(:user) }
  let(:search) { '{ searchPosts(term: "x") { title } }' }
  let(:create_tag) { 'mutation($name: String!) { createTag(name: $name) { name } }' }

  def graphql_from(ip, query, variables: {}, as: nil)
    post '/graphql', params: { query: query, variables: variables }, headers: auth_headers(as), env: { 'REMOTE_ADDR' => ip }, as: :json
    response.parsed_body
  end

  def count(key) = Rails.cache.read(key, raw: true).to_i

  it "answers a 429 past a field's limit, as rate_limit's default with:, counting apart from the endpoint's rate_limit" do
    11.times { graphql_from('10.1.0.1', search) }

    expect(response).to have_http_status(:too_many_requests)
    expect(graphql_from('10.1.0.1', '{ publishedPostCount }')['errors']).to be_nil
    expect(count('rate-limit:graphql:Query.searchPosts:10.1.0.1')).to eq(11)
    expect(count('rate-limit:graphql:endpoint:10.1.0.1')).to eq(12)
  end

  it 'answers the 429 in development too, where other errors render as JSON' do
    allow(Rails.env).to receive(:development?).and_return(true)
    11.times { graphql_from('10.1.0.4', search) }

    expect(response).to have_http_status(:too_many_requests)
  end

  it "counts each user with by:, and ends the request with with:'s response before the mutation runs" do
    20.times { |i| graphql_from('10.1.0.2', create_tag, variables: { name: "tag#{i}" }, as: user) }

    expect { graphql_from('10.1.0.2', create_tag, variables: { name: 'one more' }, as: user) }.not_to change(Tag, :count)
    expect(response).to have_http_status(:too_many_requests)
    expect(error_messages(response.parsed_body)).to eq(['Too many requests. Try again later.'])
    expect(count("rate-limit:graphql:Mutation.createTag:#{user.id}")).to eq(21)
    expect(graphql_from('10.1.0.2', create_tag, variables: { name: 'another user' }, as: create(:user))['errors']).to be_nil
  end

  it "is instrumented as rate_limit's refusals are" do
    events = []
    callback = ->(*, payload) { events << payload.slice(:name, :scope, :by, :count, :to) }
    ActiveSupport::Notifications.subscribed(callback, 'rate_limit.action_controller') { 11.times { graphql_from('10.1.0.3', search) } }

    expect(events).to eq([{ name: 'Query.searchPosts', scope: 'graphql', by: '10.1.0.3', count: 11, to: 10 }])
  end
end
