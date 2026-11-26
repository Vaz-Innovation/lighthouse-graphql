# frozen_string_literal: true

# Resolves Subscription.retitled.
class Subscriptions::Retitled < GraphQL::Schema::Subscription
  include Lighthouse::GraphQL::Subscription
end

RSpec.describe Lighthouse::GraphQL::EventStream do
  let(:cable) { FakeActionCable.new }
  let(:backend) { { GraphQL::Subscriptions::ActionCableSubscriptions => { action_cable: cable, serializer: InMemorySerializer } } }
  let(:schema) do
    Lighthouse::GraphQL::SchemaFactory.build_base_schema(sdl: <<~GRAPHQL, schema_options: { using: backend })
      type Query { post(id: ID! @eq): Post @find }
      type Mutation { retitle(id: ID!, title: String!): Post @update @broadcast(subscription: "retitled") }
      type Subscription { retitled: Post }
      type Post { id: ID! title: String }
    GRAPHQL
  end
  let(:post) { Post.create!(title: 'Draft') }
  let(:errors) { [] }

  def stream(query, keep_alive: 0.05, on_end: nil)
    on_error = ->(error) { errors << error }
    described_class.new(schema, pubsub: cable.server.pubsub, keep_alive: keep_alive, on_error: on_error, on_end: on_end).tap do |stream|
      stream.start(schema.execute(query, variables: { 'id' => post.id.to_s }, context: { channel: stream }))
    end
  end

  def retitle(title)
    schema.execute('mutation($id: ID!, $title: String!) { retitle(id: $id, title: $title) { id } }',
                   variables: { 'id' => post.id.to_s, 'title' => title })
  end

  # The subscriptions the backend keeps (ActionCableSubscriptions has no reader for them).
  def kept = schema.subscriptions.instance_variable_get(:@subscriptions).keys

  # Each event the body writes, with `on_event` called after each.
  def events_of(stream, &on_event)
    [].tap do |events|
      stream.each do |event|
        events << event
        on_event&.call(event, events)
      end
    end
  end

  def accepted(*accepts) = accepts.map { |accept| described_class.accepted?(accept) }

  it 'answers a query with one next event, then complete' do
    events = events_of(stream('query($id: ID!) { post(id: $id) { title } }'))

    expect(events).to eq([described_class.event({ 'data' => { 'post' => { 'title' => 'Draft' } } }), described_class::COMPLETE])
  end

  it 'answers an operation with errors with them, then complete' do
    events = events_of(stream('query { nothing }'))

    expect(described_class.parse(events.join).first['errors'].first['message']).to include('nothing')
    expect(events.last).to eq(described_class::COMPLETE)
  end

  it 'streams each update of a subscription, and completes once the server ends it' do
    subscription = stream('subscription { retitled { title } }')
    expect(kept).to eq([subscription.subscription_id])

    retitle('One')
    events = events_of(subscription) do |event, written|
      retitle('Two') if written.size == 1
      schema.subscriptions.delete_subscription(subscription.subscription_id) if event.include?('Two')
    end

    expect(described_class.parse(events.join).map { |result| result.dig('data', 'retitled', 'title') }).to eq(%w[One Two])
    expect(events.last).to eq(described_class::COMPLETE)
    expect(cable.server.pubsub.channels).to be_empty
    expect(errors).to be_empty
  end

  it 'writes a keep-alive comment while no update comes' do
    subscription = stream('subscription { retitled { title } }', keep_alive: 0.01)
    events = events_of(subscription) { |_, written| subscription.finish if written.size == 3 }

    expect(events.first(3)).to all(eq(described_class::KEEP_ALIVE))
  end

  it 'stops listening and forgets the subscription when the client goes away' do
    ended = false
    subscription = stream('subscription { retitled { title } }', keep_alive: 0.01, on_end: -> { ended = true })

    subscription.each { |event| raise IOError, "closed stream: #{event}" if event }

    expect(cable.server.pubsub.channels).to be_empty
    expect(kept).to be_empty
    expect(ended).to be(true)
    expect(errors).to be_empty
  end

  it 'reads which Accept headers take it' do
    expect(accepted('text/event-stream', 'text/event-stream;charset=utf-8', 'application/json,TEXT/EVENT-STREAM')).to all(be(true))
    expect(accepted('application/json', '*/*', nil)).to all(be(false))
  end
end
