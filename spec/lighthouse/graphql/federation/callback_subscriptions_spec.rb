# frozen_string_literal: true

# Resolves Subscription.postRenamed: every subscriber, or those of one author.
class Subscriptions::PostRenamed < GraphQL::Schema::Subscription
  include Lighthouse::GraphQL::Subscription

  def filter?(post, author: nil)
    author.nil? || post.author_id.to_s == author.to_s
  end
end

RSpec.describe Lighthouse::GraphQL::Federation::CallbackSubscriptions do
  # Apollo Router's callback endpoint: the messages it got, and its answers.
  let(:router) do
    Class.new do
      attr_reader :messages
      attr_accessor :answers

      def initialize
        @messages = []
        @answers = { 'check' => 204, 'next' => 200, 'complete' => 202 }
      end

      def post(url, body)
        message = JSON.parse(body)
        @messages << message.merge('url' => url)
        answers.fetch(message['action'])
      end

      def actions = messages.map { |message| message['action'] }
    end.new
  end

  let(:sdl) do
    <<~GRAPHQL
      extend schema @link(url: "https://specs.apollo.dev/federation/v2.9", import: ["@key"])

      type Query { post(id: ID! @eq): Post @find }
      type Mutation { renamePost(id: ID!, title: String!): Post @update @broadcast(subscription: "postRenamed") }
      type Subscription { postRenamed(author: ID): Post }
      type Post @key(fields: "id") { id: ID! title: String authorId: ID }
    GRAPHQL
  end

  let(:schema) do
    Lighthouse::GraphQL::SchemaFactory.build_base_schema(sdl: sdl, schema_options: { using: { described_class => { client: router, tick: 60 } } })
  end

  let(:backend) { schema.subscriptions }
  let(:post) { Post.create!(title: 'Draft', author_id: 7) }

  def extensions(id, heartbeat: 5000)
    { 'subscription' => { 'callbackUrl' => "http://router/callback/#{id}", 'subscriptionId' => id, 'verifier' => "v-#{id}",
                          'heartbeatIntervalMs' => heartbeat } }
  end

  # What the router's request runs, and what the controller answers it.
  def subscribe(query, id:, context: {})
    result = schema.execute(query, context: context.merge(described_class.context_for(extensions(id))))
    described_class.response(result)
  end

  it 'checks the callback, keeps the subscription and answers { data: null }' do
    expect(subscribe('subscription { postRenamed { title } }', id: 'sub-1')).to eq([{ 'data' => nil }, 200])

    expect(router.messages).to eq([{ 'kind' => 'subscription', 'action' => 'check', 'id' => 'sub-1', 'verifier' => 'v-sub-1',
                                     'url' => 'http://router/callback/sub-1' }])
    expect(backend.subscription_ids).to eq(['sub-1'])
  end

  it 'sends every update a mutation broadcasts as a next message, to the subscribers it is for' do
    subscribe('subscription { postRenamed { title } }', id: 'all')
    subscribe('subscription { postRenamed(author: 7) { title } }', id: 'author-7')
    subscribe('subscription { postRenamed(author: 8) { title } }', id: 'author-8')

    schema.execute('mutation($id: ID!) { renamePost(id: $id, title: "Final") { id } }', variables: { 'id' => post.id.to_s })

    updates = router.messages.select { |message| message['action'] == 'next' }
    expect(updates.pluck('id')).to contain_exactly('all', 'author-7')
    expect(updates.pluck('payload').uniq).to eq([{ 'data' => { 'postRenamed' => { 'title' => 'Final' } } }])
    expect(updates.pluck('verifier')).to contain_exactly('v-all', 'v-author-7')
  end

  it 'drops a subscription the router answers 404 for' do
    subscribe('subscription { postRenamed { title } }', id: 'gone')
    router.answers['next'] = 404

    schema.execute('mutation($id: ID!) { renamePost(id: $id, title: "Final") { id } }', variables: { 'id' => post.id.to_s })

    expect(backend.subscription_ids).to be_empty
  end

  it 'keeps nothing, and answers 400, when the router refuses the check' do
    router.answers['check'] = 400

    expect(subscribe('subscription { postRenamed { title } }', id: 'refused').last).to eq(400)
    expect(backend.subscription_ids).to be_empty
  end

  it 'sends a check heartbeat when one is due, and drops a subscription the router ended' do
    subscribe('subscription { postRenamed { title } }', id: 'beating', context: {})
    subscribe('subscription { postRenamed { title } }', id: 'ended')
    clock = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    backend.heartbeat!(clock + 1)
    expect(router.actions.count('check')).to eq(2)

    router.answers['check'] = 404
    backend.heartbeat!(clock + 6)
    expect(router.actions.count('check')).to eq(4)
    expect(backend.subscription_ids).to be_empty
  end

  it 'tells the router a subscription ended here' do
    subscribe('subscription { postRenamed { title } }', id: 'done')

    backend.delete_subscription('done')

    expect(router.messages.last).to include('action' => 'complete', 'id' => 'done')
    expect(backend.subscription_ids).to be_empty
  end

  it 'refuses a subscription that came through neither the router, SSE nor a channel' do
    result = schema.execute('subscription { postRenamed { title } }')

    expect(result['errors'].pluck('message')).to include(/Apollo Router HTTP callbacks, Server-Sent Events .* or Action Cable/)
    expect(described_class.response(result)).to be_nil
  end

  context 'with Action Cable' do
    let(:cable) { FakeActionCable.new }
    let(:schema) do
      Lighthouse::GraphQL::SchemaFactory.build_base_schema(
        sdl: sdl, schema_options: { using: { described_class => { client: router, tick: 60, action_cable: cable, serializer: InMemorySerializer } } }
      )
    end

    it "updates the router's subscriptions and an event stream's with one trigger, through its pubsub" do
      subscribe('subscription { postRenamed { title } }', id: 'routed')
      stream = Lighthouse::GraphQL::EventStream.new(schema, pubsub: cable.server.pubsub, keep_alive: 0.05)
      stream.start(schema.execute('subscription { postRenamed { title } }', context: { channel: stream }))

      schema.execute('mutation($id: ID!) { renamePost(id: $id, title: "Both") { id } }', variables: { 'id' => post.id.to_s })
      stream_id = (backend.subscription_ids - ['routed']).first
      events = []
      # Ended on the server once the update is out: the stream completes.
      stream.each do |event|
        events << event
        backend.delete_subscription(stream_id) if event.start_with?('event: next')
      end

      expect(router.messages.select { |message| message['action'] == 'next' }.pluck('payload'))
        .to eq([{ 'data' => { 'postRenamed' => { 'title' => 'Both' } } }])
      expect(Lighthouse::GraphQL::EventStream.parse(events.join)).to eq([{ 'data' => { 'postRenamed' => { 'title' => 'Both' } } }])
      expect(events.last).to eq(Lighthouse::GraphQL::EventStream::COMPLETE)
      expect(backend.subscription_ids).to eq(['routed'])
    end
  end

  it 'reads the extension from a JSON string or parameters, and ignores any other' do
    expect(described_class.context_for(extensions('x').to_json).values.first.id).to eq('x')
    expect(described_class.context_for({ 'persistedQuery' => {} })).to eq({})
    expect(described_class.context_for(nil)).to eq({})
  end
end
