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
    let(:schema) { build_schema('type Query { ping: Int @throttle(maxAttempts: 2) @field(resolver: "ThrottleSpecPing") }') }

    before do
      stub_const('ThrottleSpecPing', ->(*) { 1 })
      Lighthouse.configure { |c| c.cache_store = ActiveSupport::Cache::MemoryStore.new }
    end

    it 'refuses a client past maxAttempts, counting each client apart' do
      results = Array.new(3) { schema.execute('{ ping }', context: { remote_ip: '1.1.1.1' }).to_h }

      expect(results.map { |result| result.dig('data', 'ping') }).to eq([1, 1, nil])
      expect(results.last['errors'].pluck('message')).to eq(['Rate limit for Query.ping exceeded. Try again later.'])
      expect(schema.execute('{ ping }', context: { remote_ip: '2.2.2.2' }).to_h.dig('data', 'ping')).to eq(1)
      expect(schema.execute('{ ping }', context: { current_user: Struct.new(:id).new(7), remote_ip: '1.1.1.1' }).to_h.dig('data', 'ping')).to eq(1)
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
