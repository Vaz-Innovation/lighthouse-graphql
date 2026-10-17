require 'rails_helper'

# The channel's own behaviour, with ActionCable's test helpers (streams are stubbed
# here: spec/subscriptions/delivery_spec.rb covers the updates reaching a client).
RSpec.describe GraphqlChannel, type: :channel do
  let(:user) { create(:user) }

  def execute(query, **extra)
    perform :execute, { 'query' => query }.merge(extra.stringify_keys)
    transmissions.last
  end

  def registered_subscription_ids
    subscription.streams.filter_map { |stream| stream.delete_prefix('graphql-subscription:') if stream.start_with?('graphql-subscription:') }
  end

  before do
    stub_connection current_user: user
    subscribe
  end

  it 'confirms the connection to the channel' do
    expect(subscription).to be_confirmed
  end

  describe 'executing a subscription' do
    it 'registers it, streams its updates and answers that more will follow' do
      response = execute('subscription { postPublished { title } }')

      expect(response['result']).to eq('data' => {})
      expect(response['more']).to be(true)
      expect(registered_subscription_ids.size).to eq(1)
      expect(AppSchema.subscriptions.read_subscription(registered_subscription_ids.first)).to include(operation_name: nil)
    end

    it 'streams the field on one topic per field, whatever its arguments (the Lighthouse concern topic)' do
      execute('subscription { postPublished(authorId: 1) { title } }')

      expect(subscription.streams).to include('graphql-event::postPublished')
    end

    it 'takes variables, given as a JSON string as well' do
      execute('subscription($author: ID) { postPublished(authorId: $author) { title } }', variables: { author: '1' }.to_json)

      expect(transmissions.last['result']).to eq('data' => {})
      expect(registered_subscription_ids.size).to eq(1)
    end

    it 'reaches the subscription classes with the signed-in user' do
      response = execute('subscription { postCreated { title } }')

      expect(response['result']).to eq('data' => {})
      expect(registered_subscription_ids.size).to eq(1)
    end
  end

  describe 'a subscription that is refused' do
    before do
      stub_connection current_user: nil
      subscribe
    end

    it 'tells a guest to sign in, and registers nothing' do
      response = execute('subscription { postCreated { title } }')

      expect(response['result']['errors'].pluck('message')).to eq(['Sign in to subscribe to new posts.'])
      expect(registered_subscription_ids).to be_empty
    end

    it 'lets a guest subscribe to what is public' do
      execute('subscription { postPublished { title } }')

      expect(registered_subscription_ids.size).to eq(1)
    end
  end

  describe 'an operation that is not a subscription' do
    it 'is answered once, with no more to come' do
      response = execute('{ publishedPostCount }')

      expect(response).to include('more' => false, 'result' => { 'data' => { 'publishedPostCount' => 0 } })
      expect(registered_subscription_ids).to be_empty
    end
  end

  describe 'unsubscribing' do
    it 'deletes the subscriptions of the socket' do
      execute('subscription { postPublished { title } }')
      execute('subscription { postCreated { title } }')
      ids = registered_subscription_ids
      expect(ids.map { |id| AppSchema.subscriptions.read_subscription(id) }).to all(be_present)

      unsubscribe

      expect(ids.map { |id| AppSchema.subscriptions.read_subscription(id) }).to all(be_nil)
    end

    it 'leaves the subscriptions of other sockets alone' do
      execute('subscription { postPublished { title } }')
      theirs = AppSchema.execute('subscription { postPublished { title } }', context: { channel: Class.new { def stream_from(*) = nil }.new })
      their_id = theirs.context[:subscription_id]

      unsubscribe

      expect(AppSchema.subscriptions.read_subscription(their_id)).to be_present
    end
  end
end
