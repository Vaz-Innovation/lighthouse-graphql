require 'rails_helper'

# What depends on the database, the queue and the cache the app really runs on.
# It runs on SQLite by default; CI runs it again on PostgreSQL and MySQL
# (DATABASE_URL), with Redis (REDIS_URL):
#
#   DATABASE_URL=postgres://postgres:postgres@127.0.0.1:5433/lighthouse_example_test \
#   REDIS_URL=redis://127.0.0.1:6380/0 bundle exec rspec spec/requests/graphql/real_backends_spec.rb
RSpec.describe "GraphQL on the app's real backends (#{ActiveRecord::Base.connection_db_config.adapter})", type: :request do
  def adapter = ActiveRecord::Base.connection.adapter_name

  # A request from `ip`, as the controller concern sees it (request.remote_ip).
  def graphql_from(ip, query, as: nil)
    post '/graphql', params: { query: query }, headers: auth_headers(as), env: { 'REMOTE_ADDR' => ip }, as: :json
    response.parsed_body
  end

  def status_from(...) = graphql_from(...) && response.status

  describe '@whereJsonContains' do
    before do
      create(:post, title: 'Both', metadata: { labels: %w[ruby graphql] })
      create(:post, title: 'Ruby', metadata: { labels: %w[ruby] })
      create(:post, title: 'Elsewhere', metadata: { series: 'graphql', labels: [] })
      create(:post, title: 'None', metadata: nil)
    end

    def titles(arguments) = graphql("{ posts(#{arguments}, first: 10) { data { title } } }").dig('data', 'posts', 'data').pluck('title')

    it "keeps the posts whose JSON array, at the key's path, holds the label" do
      expect(titles('label: "graphql"')).to eq(['Both'])
      expect(titles('label: "ruby"')).to contain_exactly('Both', 'Ruby')
    end

    it 'keeps the posts that hold every label of a list' do
      expect(titles('labels: ["ruby", "graphql"]')).to eq(['Both'])
      expect(titles('labels: ["ruby", "rails"]')).to eq([])
    end
  end

  describe '@async through Solid Queue' do
    # The worker runs in its own thread, on its own connection: it sees only
    # committed rows, so this group commits, and empties the tables after.
    self.use_transactional_tests = false

    around do |example|
      adapter = ActiveJob::Base.queue_adapter
      ActiveJob::Base.queue_adapter = :solid_queue
      example.run
    ensure
      ActiveJob::Base.queue_adapter = adapter
      connection = ActiveRecord::Base.connection
      connection.disable_referential_integrity do
        (connection.tables - %w[schema_migrations ar_internal_metadata]).each do |table|
          connection.execute("DELETE FROM #{connection.quote_table_name(table)}")
        end
      end
    end

    def eventually(timeout: 15)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      sleep 0.05 until yield || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      yield
    end

    it 'queues the mutation in the database, and a Solid Queue worker runs it' do
      author = create(:user)
      draft = create(:post, :draft, author: author)

      body = graphql("mutation { schedulePublish(id: #{draft.id}) }", as: author)

      expect(body).to eq('data' => { 'schedulePublish' => true })
      expect(draft.reload).not_to be_published
      job = SolidQueue::Job.last
      expect(job.class_name).to eq('Lighthouse::GraphQL::AsyncMutationJob')
      expect(job.arguments['arguments'].first(3)).to eq(%w[AppSchema Mutation schedulePublish])

      worker = SolidQueue::Worker.new(queues: '*', threads: 1, polling_interval: 0.05)
      worker.mode = :async
      worker.start
      begin
        expect(eventually { draft.reload.published? }).to be(true)
        expect(eventually { job.reload.finished? }).to be(true)
      ensure
        worker.stop
      end
    end

    it 'queues nothing when @canFind refuses the call' do
      draft = create(:post, :draft)

      body = graphql("mutation { schedulePublish(id: #{draft.id}) }", as: create(:user))

      expect(error_messages(body)).to eq(['This action is unauthorized.'])
      expect(SolidQueue::Job.count).to eq(0)
    end
  end

  describe '@throttle on a shared cache store' do
    stores = { 'a file store' => -> { ActiveSupport::Cache::FileStore.new(Rails.root.join('tmp/cache/throttle_spec')) } }
    if ENV['REDIS_URL']
      stores['Redis'] = lambda {
        require 'redis'
        ActiveSupport::Cache::RedisCacheStore.new(url: ENV.fetch('REDIS_URL'), namespace: 'throttle_spec')
      }
    end

    stores.each do |name, build|
      context "with #{name}" do
        let(:store) { build.call.tap(&:clear) }
        let(:search) { '{ searchPosts(term: "x") { title } }' }

        # Where Rails' rate_limit counts too: the controller's cache_store.
        around do |example|
          previous = GraphqlController.cache_store
          GraphqlController.cache_store = store
          example.run
        ensure
          GraphqlController.cache_store = previous
        end

        it 'answers a client its eleventh search in a minute with a 429, counting each IP apart, as rate_limit' do
          ten = Array.new(10) { graphql_from('10.0.0.1', search) }

          expect(ten.pluck('errors')).to all(be_nil)
          expect(status_from('10.0.0.1', search)).to eq(429)
          expect(status_from('10.0.0.2', search)).to eq(200)
          expect(status_from('10.0.0.1', search, as: create(:user))).to eq(429)
        end

        it 'counts on another app server too: the count lives in the store, not in the process' do
          10.times { graphql_from('10.0.0.3', search) }
          GraphqlController.cache_store = build.call # a new client of the same store, as another server holds
          graphql_from('10.0.0.3', search)

          expect(response).to have_http_status(:too_many_requests)
        end
      end
    end
  end
end
