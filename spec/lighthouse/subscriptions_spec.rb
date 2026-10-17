# frozen_string_literal: true

require 'active_job'
require 'active_job/test_helper'

ActiveJob::Base.logger = Logger.new(nil)

# Fixture classes a Subscription field resolves to by convention (Subscriptions::PostUpdated
# for Subscription.postUpdated) or through @subscription(class:).
module Subscriptions
  # PHP Lighthouse's filter(): the subscriber's `author` argument narrows the broadcast.
  class PostUpdated < Lighthouse::GraphQL::Subscription
    def filter?(post, author: nil)
      author.nil? || post.author_id.to_s == author.to_s
    end
  end

  class AdminPosts < Lighthouse::GraphQL::Subscription
    def authorize?(**)
      context[:admin] == true
    end
  end

  class ShoutedPosts < Lighthouse::GraphQL::Subscription
    def resolve_payload(post, **)
      post.tap { |p| p.title = p.title.upcase }
    end
  end

  # A plain graphql-ruby subscription: exact-argument topics, so the trigger names them.
  class PostsByAuthor < GraphQL::Schema::Subscription
    argument :author, GraphQL::Types::ID, required: true

    def self.trigger_arguments(post, _context) = { author: post.author_id.to_s }
  end

  class ExactPosts < Lighthouse::GraphQL::Subscription
    topic_by :arguments

    def self.trigger_arguments(post, _context) = { author: post.author_id.to_s }
  end

  class Scoped < Lighthouse::GraphQL::Subscription
    subscription_scope :tenant

    def self.trigger_scope(post, _context) = "tenant-#{post.author_id}"
  end

  class NotASubscription
    def self.call(*) = nil
  end
end

module Blog; end

class Blog::Announcements < Lighthouse::GraphQL::Subscription
  def resolve_payload(post, **) = post.tap { |p| p.title = "Announced: #{p.title}" }
end

RSpec.describe 'Subscriptions (@subscription, @broadcast)' do
  include ActiveJob::TestHelper

  let(:sdl) do
    <<~GRAPHQL
      type Query {
        posts: [Post!]! @all
      }

      type Mutation {
        createPost(title: String!, author_id: Int): Post @create @broadcast(subscription: "postCreated")
        updatePost(id: ID!, title: String, author_id: Int): Post
          @update
          @broadcast(subscription: "postUpdated")
          @broadcast(subscription: "postsByAuthor")
          @broadcast(subscription: "exactPosts")
          @broadcast(subscription: "shoutedPosts")
        publishAdminPost(title: String!): Post @create(model: "Post") @broadcast(subscription: "adminPosts")
        announce(title: String!): Post @create(model: "Post") @broadcast(subscription: "announcements")
        failToCreate(title: String): Post @field(resolver: "SubscriptionsSpecFailing") @broadcast(subscription: "postCreated")
        scopedPost(title: String!, author_id: Int): Post @create(model: "Post") @broadcast(subscription: "scoped")
      }

      type Subscription {
        postCreated: Post
        postUpdated(author: ID): Post
        adminPosts: Post
        shoutedPosts: Post
        postsByAuthor(author: ID!): Post
        exactPosts(author: ID!): Post
        announcements: Post @subscription(class: "Blog::Announcements")
        scoped: Post
      }

      type Post {
        id: ID!
        title: String
        authorId: ID
      }
    GRAPHQL
  end

  let(:dataloader) { false }
  let(:using) { { InMemorySubscriptions => {} }.merge(dataloader ? { GraphQL::Dataloader => {} } : {}) }
  let(:schema) { Lighthouse::GraphQL::SchemaFactory.build_base_schema(sdl: sdl, schema_options: { using: using }) }
  let(:backend) { schema.subscriptions }

  # Subscribe as `id` with the given context; the initial response carries no data.
  def subscribe(query, id:, context: {})
    result = schema.execute(query, context: { subscription_id: id }.merge(context))
    result.to_h
  end

  def mutate(query)
    result = schema.execute(query).to_h
    expect(result['errors']).to be_nil
    result
  end

  def titles(id)
    backend.payloads_for(id).map { |payload| payload['data'].values.first['title'] }
  end

  before do
    stub_const('SubscriptionsSpecFailing', Class.new do
      def self.call(*) = GraphQL::ExecutionError.new('nope')
    end)
  end

  describe 'subscribing' do
    it 'registers the subscription with the schema backend, and answers nothing yet' do
      result = subscribe('subscription { postCreated { title } }', id: 'one')

      expect(result['errors']).to be_nil
      expect(backend.registered.map { |id, event| [id, event.name] }).to eq([%w[one postCreated]])
      expect(backend.subscription_ids).to eq(['one'])
    end

    it 'registers a field resolved by a conventional class' do
      subscribe('subscription { postUpdated(author: "3") { title } }', id: 'one')

      expect(backend.registered.map { |_, event| event.name }).to eq(['postUpdated'])
    end

    it 'shares one topic between subscribers with different arguments, so filter? decides who is updated' do
      subscribe('subscription { postUpdated(author: "3") { title } }', id: 'three')
      subscribe('subscription { postUpdated(author: "4") { title } }', id: 'four')

      expect(backend.registered.map { |_, event| event.topic }.uniq.size).to eq(1)
    end
  end

  shared_examples 'a broadcast' do
    it 'delivers the created record of a @create mutation to the subscribers of the field' do
      subscribe('subscription { postCreated { id title } }', id: 'one')
      subscribe('subscription { postCreated { title } }', id: 'two')

      mutate('mutation { createPost(title: "Hello") { id } }')

      expect(titles('one')).to eq(['Hello'])
      expect(titles('two')).to eq(['Hello'])
      expect(backend.payloads_for('one').first.dig('data', 'postCreated', 'id')).to eq(Post.last.id.to_s)
    end

    it 'delivers nothing when nobody subscribed, or to another field' do
      subscribe('subscription { postUpdated { title } }', id: 'other')

      mutate('mutation { createPost(title: "Hello") { id } }')

      expect(backend.deliveries).to be_empty
    end

    it 'skips the subscribers a class-defined filter? turns down' do
      post = Post.create!(title: 'Old', author_id: 3)
      subscribe('subscription { postUpdated(author: "3") { title } }', id: 'owner')
      subscribe('subscription { postUpdated(author: "4") { title } }', id: 'stranger')
      subscribe('subscription { postUpdated { title } }', id: 'everyone')

      mutate("mutation { updatePost(id: #{post.id}, title: \"New\") { id } }")

      expect(titles('owner')).to eq(['New'])
      expect(titles('everyone')).to eq(['New'])
      expect(backend.payloads_for('stranger')).to be_empty
    end

    it 'triggers once for each @broadcast, each subscription receiving its own update' do
      post = Post.create!(title: 'Old', author_id: 3)
      subscribe('subscription { postUpdated { title } }', id: 'updated')
      subscribe('subscription { shoutedPosts { title } }', id: 'shouted')

      mutate("mutation { updatePost(id: #{post.id}, title: \"New\") { id } }")

      expect(backend.deliveries.map(&:first)).to contain_exactly('updated', 'shouted')
      expect(titles('updated')).to eq(['New'])
      expect(titles('shouted')).to eq(['NEW'])
    end

    it 'does not broadcast a mutation that failed' do
      subscribe('subscription { postCreated { title } }', id: 'one')

      result = schema.execute('mutation { failToCreate(title: "x") { id } }').to_h

      expect(result['errors'].first['message']).to eq('nope')
      expect(backend.deliveries).to be_empty
    end

    it 'does not broadcast when validation rejects the record' do
      subscribe('subscription { postCreated { title } }', id: 'one')

      result = schema.execute("mutation { createPost(title: \"#{'x' * 30}\") { id } }").to_h

      expect(result['errors']).not_to be_empty
      expect(backend.deliveries).to be_empty
    end

    it 'gives a graphql-ruby subscription its own trigger_arguments, matched against its subscribers exactly' do
      post = Post.create!(title: 'Old', author_id: 3)
      subscribe('subscription { postsByAuthor(author: "3") { title } }', id: 'owner')
      subscribe('subscription { postsByAuthor(author: "4") { title } }', id: 'stranger')

      mutate("mutation { updatePost(id: #{post.id}, title: \"New\") { id } }")

      expect(titles('owner')).to eq(['New'])
      expect(backend.payloads_for('stranger')).to be_empty
    end

    it 'matches subscribers by arguments with topic_by :arguments' do
      post = Post.create!(title: 'Old', author_id: 3)
      subscribe('subscription { exactPosts(author: "3") { title } }', id: 'owner')
      subscribe('subscription { exactPosts(author: "4") { title } }', id: 'stranger')

      mutate("mutation { updatePost(id: #{post.id}, title: \"New\") { id } }")

      expect(titles('owner')).to eq(['New'])
      expect(backend.payloads_for('stranger')).to be_empty
    end

    it 'scopes the trigger with trigger_scope' do
      subscribe('subscription { scoped { title } }', id: 'mine', context: { tenant: 'tenant-3' })
      subscribe('subscription { scoped { title } }', id: 'theirs', context: { tenant: 'tenant-4' })

      mutate('mutation { scopedPost(title: "Hello", author_id: 3) { id } }')

      expect(titles('mine')).to eq(['Hello'])
      expect(backend.payloads_for('theirs')).to be_empty
    end
  end

  context 'with graphql-ruby running fields directly' do
    it_behaves_like 'a broadcast'
  end

  context 'with the dataloader' do
    let(:dataloader) { true }

    it_behaves_like 'a broadcast'
  end

  describe 'the class a field resolves to' do
    it 'uses the first namespace of Config.namespaces[:subscriptions] that has it' do
      Lighthouse.configure { |c| c.namespaces = { subscriptions: %w[Nothing Subscriptions] } }
      Post.create!(title: 'Old', author_id: 3)
      subscribe('subscription { shoutedPosts { title } }', id: 'one')

      mutate("mutation { updatePost(id: #{Post.last.id}, title: \"New\") { id } }")

      expect(titles('one')).to eq(['NEW'])
    end

    it 'is the one @subscription(class:) names, fully qualified' do
      subscribe('subscription { announcements { title } }', id: 'one')

      mutate('mutation { announce(title: "Hi") { id } }')

      expect(titles('one')).to eq(['Announced: Hi'])
    end

    it 'is looked up in the namespaces for a class name alone' do
      Lighthouse.configure { |c| c.namespaces = { subscriptions: ['Blog'] } }
      subscribe('subscription { announcements { title } }', id: 'one')

      mutate('mutation { announce(title: "Hi") { id } }')

      expect(titles('one')).to eq(['Announced: Hi'])
    end

    it 'is the Lighthouse subscription itself when there is none: the update is the broadcast root' do
      expect(Lighthouse::GraphQL::Broadcasting.subscription_class(schema, 'postCreated')).to eq(Lighthouse::GraphQL::Subscription)
    end

    it 'must be a GraphQL::Schema::Subscription' do
      sdl_with = "#{sdl}\nextend type Subscription { other: Post @subscription(class: \"Subscriptions::NotASubscription\") }"
      built = Lighthouse::GraphQL::SchemaFactory.build_base_schema(sdl: sdl_with, schema_options: { using: using })

      expect { built.execute('subscription { other { title } }') }
        .to raise_error(Lighthouse::DefinitionError, /Subscriptions::NotASubscription.*GraphQL::Schema::Subscription/)
    end

    it 'must exist when @subscription names it' do
      sdl_with = "#{sdl}\nextend type Subscription { other: Post @subscription(class: \"Missing\") }"
      built = Lighthouse::GraphQL::SchemaFactory.build_base_schema(sdl: sdl_with, schema_options: { using: using })

      expect { built.execute('subscription { other { title } }') }
        .to raise_error(Lighthouse::DefinitionError, /@subscription\(class: "Missing"\) on Subscription.other: no such class.*Subscriptions::Missing/)
    end

    it 'belongs to a field of the Subscription type' do
      bad = "#{sdl}\nextend type Query { oops: Post @subscription(class: \"Blog::Announcements\") }"

      expect { Lighthouse::GraphQL::SchemaFactory.build_base_schema(sdl: bad, schema_options: { using: using }) }
        .to raise_error(Lighthouse::DefinitionError, /@subscription is for fields of the Subscription type, not Query.oops/)
    end
  end

  describe 'authorize?' do
    it 'refuses the subscription it returns false for, registering nothing' do
      result = subscribe('subscription { adminPosts { title } }', id: 'one', context: { admin: false })

      expect(result['errors'].first['message']).to eq('Unauthorized subscription request.')
      expect(backend.subscription_ids).to be_empty
    end

    it 'lets the others subscribe, and be updated' do
      subscribe('subscription { adminPosts { title } }', id: 'one', context: { admin: true })

      mutate('mutation { publishAdminPost(title: "Secret") { id } }')

      expect(titles('one')).to eq(['Secret'])
    end
  end

  describe 'unsubscribing' do
    it 'stops the updates of a subscription that is gone' do
      subscribe('subscription { postCreated { title } }', id: 'one')
      backend.delete_subscription('one')

      mutate('mutation { createPost(title: "Hello") { id } }')

      expect(backend.deliveries).to be_empty
    end
  end

  describe 'a schema without a subscriptions backend' do
    let(:using) { {} }
    let(:errors) { [] }

    before { Lighthouse.configure { |c| c.on_error = ->(error, _context) { errors << error } } }

    it 'reports where to install one, and lets the mutation succeed' do
      result = mutate('mutation { createPost(title: "Hello") { title } }')

      expect(result.dig('data', 'createPost', 'title')).to eq('Hello')
      expect(errors.map(&:class)).to eq([Lighthouse::DefinitionError])
      expect(errors.first.message)
        .to match(/@broadcast\(subscription: "postCreated"\) has nowhere to broadcast.*no subscriptions backend.*ActionCableSubscriptions/)
    end

    it 'raises it under the default error handling of a test environment' do
      Lighthouse.configure { |c| c.on_error = ->(error, _context) { raise error } }

      expect { schema.execute('mutation { createPost(title: "Hello") { title } }') }
        .to raise_error(Lighthouse::DefinitionError, /no subscriptions backend/)
    end
  end

  describe 'building the schema' do
    it 'rejects a @broadcast naming a subscription the Subscription type lacks' do
      bad = sdl.sub('@broadcast(subscription: "postCreated")', '@broadcast(subscription: "postCreatd")')

      expect { Lighthouse::GraphQL::SchemaFactory.build_base_schema(sdl: bad) }
        .to raise_error(Lighthouse::DefinitionError, /@broadcast on Mutation.createPost: Subscription has no field "postCreatd"/)
    end

    it 'rejects a @broadcast in a schema with no Subscription type' do
      bad = <<~GRAPHQL
        type Query { posts: [Post!]! @all }
        type Mutation { createPost(title: String!): Post @create @broadcast(subscription: "postCreated") }
        type Post { id: ID! }
      GRAPHQL

      expect { Lighthouse::GraphQL::SchemaFactory.build_base_schema(sdl: bad) }
        .to raise_error(Lighthouse::DefinitionError, /the schema has no Subscription type/)
    end

    it 'accepts the snake_case name of a subscription' do
      snake = sdl.sub('@broadcast(subscription: "postCreated")', '@broadcast(subscription: "post_created")')
      built = Lighthouse::GraphQL::SchemaFactory.build_base_schema(sdl: snake, schema_options: { using: using })
      built.execute('subscription { postCreated { title } }', context: { subscription_id: 'one' })

      built.execute('mutation { createPost(title: "Hello") { id } }')

      expect(built.subscriptions.payloads_for('one').size).to eq(1)
    end

    it 'takes the backend from the schema options' do
      expect(schema.subscriptions).to be_a(InMemorySubscriptions)
    end
  end

  describe 'queueing' do
    let(:queued) { sdl.sub('@create @broadcast(subscription: "postCreated")', '@create @broadcast(subscription: "postCreated", shouldQueue: true)') }
    let(:schema) { Lighthouse::GraphQL::SchemaFactory.build_base_schema(sdl: queued, schema_options: { using: using }) }

    before do
      # What a Rails app's globalid railtie does, so a job can carry a model.
      GlobalID.app = 'lighthouse-spec'
      ActiveSupport.on_load(:active_record) { include GlobalID::Identification }
      ActiveJob::Base.queue_adapter = :test
      ActiveJob::Base.queue_adapter.enqueued_jobs.clear
      stub_const('SubscriptionsSpecSchema', schema)
      subscribe('subscription { postCreated { title } }', id: 'one')
    end

    after { ActiveJob::Base.queue_adapter.enqueued_jobs.clear }

    it 'enqueues a job instead of triggering, and performing it delivers the update' do
      mutate('mutation { createPost(title: "Hello") { id } }')

      expect(ActiveJob::Base.queue_adapter.enqueued_jobs.size).to eq(1)
      expect(backend.deliveries).to be_empty

      perform_enqueued_jobs

      expect(titles('one')).to eq(['Hello'])
    end

    it 'runs it in Config.broadcast_queue' do
      Lighthouse.configure { |c| c.broadcast_queue = 'subscriptions' }

      mutate('mutation { createPost(title: "Hello") { id } }')

      expect(ActiveJob::Base.queue_adapter.enqueued_jobs.first['queue_name']).to eq('subscriptions')
    end

    it 'queues every broadcast with Config.queue_broadcasts, unless shouldQueue: false' do
      Lighthouse.configure { |c| c.queue_broadcasts = true }
      sdl_for_config = sdl.sub('@broadcast(subscription: "postCreated")', '@broadcast(subscription: "postCreated", shouldQueue: false)')
      built = Lighthouse::GraphQL::SchemaFactory.build_base_schema(sdl: sdl_for_config, schema_options: { using: using })
      built.execute('subscription { postCreated { title } }', context: { subscription_id: 'two' })
      stub_const('SubscriptionsSpecSchema', built)

      built.execute('mutation { createPost(title: "Inline") { id } }')

      expect(ActiveJob::Base.queue_adapter.enqueued_jobs).to be_empty
      expect(built.subscriptions.payloads_for('two').size).to eq(1)
    end

    it 'asks for a named schema' do
      anonymous = Lighthouse::GraphQL::SchemaFactory.build_base_schema(sdl: queued, schema_options: { using: using })

      expect { anonymous.execute('mutation { createPost(title: "Hello") { id } }') }
        .to raise_error(Lighthouse::DefinitionError, /assign it to a constant/)
    end
  end

  describe 'Config' do
    it 'does not queue broadcasts by default, and has no broadcast queue' do
      expect(Lighthouse::Config.queue_broadcasts).to be(false)
      expect(Lighthouse::Config.broadcast_queue).to be_nil
      expect(Lighthouse::Config.namespaces[:subscriptions]).to eq(['Subscriptions'])
    end
  end
end
