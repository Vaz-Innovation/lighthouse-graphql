# frozen_string_literal: true

require 'active_job'

# @enum, @namespaced, @hide / @show, @throttle and @async.
RSpec.describe 'Execution directives' do
  describe '@enum' do
    let(:schema) do
      build_schema(<<~GRAPHQL)
        type Query {
          posts(published: Visibility @eq): [Post!]! @all
        }
        enum Visibility { LIVE @enum(value: true) DRAFT @enum(value: false) }
        type Post { title: String visibility: Visibility @rename(attribute: "published") }
      GRAPHQL
    end

    it 'reads an enum value as its internal value, and answers one with its key' do
      Post.create!(title: 'Live', published: true)
      Post.create!(title: 'Draft', published: false)

      expect(schema.execute('{ posts(published: DRAFT) { title visibility } }').to_h.dig('data', 'posts'))
        .to eq([{ 'title' => 'Draft', 'visibility' => 'DRAFT' }])
    end
  end

  describe '@namespaced' do
    it 'groups fields under one that resolves to true' do
      Post.create!(title: 'Hello')
      schema = build_schema(<<~GRAPHQL)
        type Query { post: PostQueries! @namespaced }
        type PostQueries { first: Post @first(model: "Post") count: Int! @count(model: "Post") }
        type Post { title: String }
      GRAPHQL

      expect(schema.execute('{ post { first { title } count } }').to_h).to eq('data' => { 'post' => { 'first' => { 'title' => 'Hello' },
                                                                                                      'count' => 1 } })
    end
  end

  describe '@hide and @show' do
    let(:sdl) do
      <<~GRAPHQL
        type Query {
          always: String
          debug: String @show(env: ["development"])
          legacy: String @hide(env: ["test"])
          testOnly: String @show(env: ["test"])
        }
      GRAPHQL
    end

    it 'leaves a field out of the schema in the environments it names' do
      allow(Lighthouse::Support::Environment).to receive(:current).and_return('test')

      expect(build_schema(sdl).query.fields.keys).to contain_exactly('always', 'testOnly')
    end

    it 'keeps it in the others' do
      allow(Lighthouse::Support::Environment).to receive(:current).and_return('development')

      expect(build_schema(sdl).query.fields.keys).to contain_exactly('always', 'debug', 'legacy')
    end
  end

  describe '@throttle' do
    let(:schema) do
      build_schema(<<~GRAPHQL)
        type Query {
          ping: Int @throttle(maxAttempts: 2) @field(resolver: "ThrottleSpecPing")
          mine: Int @throttle(maxAttempts: 1, by: "current_user.id", name: "endpoint", prefix: "api", with: "too_many") @field(resolver: "ThrottleSpecPing")
          soft: Int @throttle(maxAttempts: 1, with: "note_it") @field(resolver: "ThrottleSpecPing")
          broken: Int @throttle(maxAttempts: 0, with: "nope") @field(resolver: "ThrottleSpecPing")
          strict: Int @throttle(maxAttempts: 0, with: "field_error") @field(resolver: "ThrottleSpecPing")
        }
      GRAPHQL
    end

    # What @throttle reads of a Rails controller, as rate_limit does.
    let(:controller_class) do
      Class.new do
        attr_reader :cache_store, :request, :notes

        def initialize = (@cache_store = ActiveSupport::Cache::MemoryStore.new) && (@request = :request) && (@notes = [])
        def controller_path = 'graphql'
        def performed? = @performed || false
        def head(status) = @performed = status

        private

        def too_many = @performed = true
        def note_it = @notes << :limited
        def field_error = raise(GraphQL::ExecutionError, 'Slow down.')
      end
    end
    let(:controller) { controller_class.new }
    let(:user) { Struct.new(:id).new(7) }

    before { stub_const('ThrottleSpecPing', ->(*) { 1 }) }

    def ping(query = '{ ping }', **context) = schema.execute(query, context: context).to_h

    it "refuses a client past maxAttempts with rate_limit's default with:, a 429" do
      stub_const('ActionController::TooManyRequests', Class.new(StandardError))
      2.times { ping(remote_ip: '1.1.1.1') }

      expect { ping(remote_ip: '1.1.1.1') }.to raise_error(ActionController::TooManyRequests)
    end

    it "answers head :too_many_requests where Rails has no TooManyRequests (7.2), as rate_limit's default did" do
      2.times { ping(remote_ip: '1.1.1.1', lighthouse_controller: controller) }

      expect { ping(remote_ip: '1.1.1.1', lighthouse_controller: controller) }.to raise_error(Lighthouse::GraphQL::Controller::Performed)
      expect(controller.performed?).to eq(:too_many_requests)
    end

    it "fails the field without Action Pack, the client being its IP, as rate_limit's default by:" do
      results = Array.new(3) { ping(remote_ip: '1.1.1.1') }

      expect(results.map { |result| result.dig('data', 'ping') }).to eq([1, 1, nil])
      expect(results.last['errors'].pluck('message')).to eq(['Rate limit for Query.ping exceeded. Try again later.'])
      expect(ping(remote_ip: '2.2.2.2').dig('data', 'ping')).to eq(1)
      expect(ping(remote_ip: '1.1.1.1', current_user: user).dig('data', 'ping')).to be_nil
    end

    it "counts in the controller's cache_store under rate_limit's key, and in Rails.cache outside a controller" do
      2.times { ping(remote_ip: '3.3.3.3', lighthouse_controller: controller) }
      ping(remote_ip: '3.3.3.3')

      expect(controller.cache_store.read('rate-limit:graphql:Query.ping:3.3.3.3', raw: true).to_i).to eq(2)
      expect(Lighthouse::GraphQL::Caching.store.read('rate-limit:Query.ping:3.3.3.3', raw: true).to_i).to eq(1)
    end

    it "reads by: off the context, as @inject, and makes prefix and name rate_limit's scope and name" do
      ping('{ mine }', remote_ip: '4.4.4.4', current_user: user, lighthouse_controller: controller)

      expect(controller.cache_store.read('rate-limit:api:endpoint:7', raw: true).to_i).to eq(1)
    end

    it "calls the controller's with: method past the limit, instrumented as rate_limit's, and stops where it performed" do
      events = []
      subscriber = ActiveSupport::Notifications.subscribe('rate_limit.action_controller') { |*, payload| events << payload }
      context = { current_user: user, lighthouse_controller: controller }

      expect(ping('{ mine }', **context).dig('data', 'mine')).to eq(1)
      expect { ping('{ mine }', **context) }.to raise_error(Lighthouse::GraphQL::Controller::Performed)
      expect(events).to eq([{ request: :request, count: 2, to: 1, within: 1.minute, by: 7, name: 'endpoint', scope: 'api',
                              cache_key: 'rate-limit:api:endpoint:7' }])
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    it 'lets the call through when with: performs nothing, and refuses as without with: outside a controller' do
      2.times { ping('{ soft }', remote_ip: '5.5.5.5', lighthouse_controller: controller) }
      outside = Array.new(2) { ping('{ soft }', remote_ip: '6.6.6.6') }

      expect(controller.notes).to eq([:limited])
      expect(outside.last['errors'].pluck('message')).to eq(['Rate limit for Query.soft exceeded. Try again later.'])
      expect { ping('{ broken }', lighthouse_controller: controller) }.to raise_error(Lighthouse::DefinitionError, /has no method nope/)
    end

    it "refuses with rate_limit's with: once the controller has performed, as long as its response is not committed" do
      stub_const('ActionController::TooManyRequests', Class.new(StandardError))
      performed = Class.new(controller_class) do
        def performed? = true
        def response = Struct.new(:committed?).new(false)
      end.new
      2.times { ping(remote_ip: '8.8.8.8', lighthouse_controller: performed) }

      expect { ping(remote_ip: '8.8.8.8', lighthouse_controller: performed) }.to raise_error(ActionController::TooManyRequests)
    end

    it 'fails only the field once the response is committed (a later part of a streamed response), calling no with:' do
      committed = Class.new(controller_class) { def response = Struct.new(:committed?).new(true) }.new
      context = { current_user: user, lighthouse_controller: committed }
      ping('{ mine }', **context)

      expect(ping('{ mine }', **context)['errors'].pluck('message')).to eq(['Rate limit for Query.mine exceeded. Try again later.'])
      expect(committed.notes).to eq([])
    end

    it 'fails only the field when with: raises a GraphQL::ExecutionError, the rest of the operation answered' do
      result = ping('{ strict ping }', remote_ip: '7.7.7.7', lighthouse_controller: controller)

      expect(result['data']).to eq('strict' => nil, 'ping' => 1)
      expect(result['errors'].pluck('message')).to eq(['Slow down.'])
    end
  end

  describe '@async' do
    include ActiveJob::TestHelper

    let(:sdl) do
      <<~GRAPHQL
        type Query { x: Int }
        type Mutation {
          publish(title: String! @trim): Boolean! @guard @async(queue: "slow") @field(resolver: "AsyncSpecPublish")
        }
      GRAPHQL
    end

    before do
      ActiveJob::Base.queue_adapter = :test
      stub_const('AsyncSpecSchema', build_schema(sdl))
      stub_const('AsyncSpecPublish', ->(_obj, args, ctx) { Post.create!(title: "#{args[:title]} by #{ctx[:current_user]}") })
    end

    it 'answers true at once, and resolves the field in a job, with the arguments and the context' do
      result = AsyncSpecSchema.execute('mutation { publish(title: " Hello ") }', context: { current_user: 'ada', request: Object.new }).to_h

      expect(result).to eq('data' => { 'publish' => true })
      expect(Post.count).to eq(0)
      expect(enqueued_jobs.last).to include(queue: 'slow')

      perform_enqueued_jobs

      expect(Post.pluck(:title)).to eq(['Hello by ada'])
    end

    it 'checks @guard in the request, queuing nothing for a guest' do
      result = AsyncSpecSchema.execute('mutation { publish(title: "x") }').to_h

      expect(result['errors'].pluck('message')).to eq(['Unauthenticated.'])
      expect(enqueued_jobs).to be_empty
    end

    it 'is for a Mutation field returning Boolean' do
      expect { build_schema('type Query { x: Int @async @field(resolver: "AsyncSpecPublish") }') }
        .to raise_error(Lighthouse::DefinitionError, /only a Mutation field returning Boolean/)
    end
  end
end
