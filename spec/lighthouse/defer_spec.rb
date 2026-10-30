# frozen_string_literal: true

# A shelf of values of two types of one interface, for a deferred fragment on one of them.
module DeferSpec
  Book = Struct.new(:title, :pages)
  Movie = Struct.new(:title, :minutes)
end

class DeferSpecShelf
  def self.call(*) = [DeferSpec::Book.new('Dune', 412), DeferSpec::Movie.new('Alien', 117), DeferSpec::Book.new('Emma', 474)]
end

class DeferSpecNames
  def self.call(*) = %w[ann bob cat dan]
end

# A value graphql-ruby syncs later (Schema.lazy_resolve), as a promise would be.
DeferSpecLazy = Struct.new(:value)

class DeferSpecLater
  def self.call(*) = DeferSpecLazy.new(%w[ann bob cat dan])
end

class DeferSpecNothing
  def self.call(*) = nil
end

# Users, with a null between them.
class DeferSpecGaps
  def self.call(*) = [LH::User.first, nil, LH::User.second]
end

# @defer (Lighthouse::GraphQL::Defer): the fields of a fragment arrive after the rest.
RSpec.describe 'Deferring fields' do
  include_context 'with PHP Lighthouse models'

  let(:sdl) do
    <<~GRAPHQL
      type Query {
        users: [User!]! @all(model: "LH::User")
        user(id: ID! @eq): User @find(model: "LH::User")
        shelf: [Titled!]! @field(resolver: "DeferSpecShelf")
        names: [String!]! @field(resolver: "DeferSpecNames")
        maybe: [String!] @field(resolver: "DeferSpecNothing")
        someNames: [String!] @field(resolver: "DeferSpecNames")
        limited: String @throttle(maxAttempts: 0) @field(resolver: "DeferSpecNames")
        noted: String @throttle(maxAttempts: 0, with: "note_it") @field(resolver: "DeferSpecNames")
        gaps: [User] @field(resolver: "DeferSpecGaps")
        strictGaps: [User!] @field(resolver: "DeferSpecGaps")
      }
      directive @mark on INLINE_FRAGMENT
      type Mutation {
        createUser(name: String!): User @create(model: "LH::User")
      }
      type User {
        id: ID!
        name: String
        company: Company @belongsTo
        posts: [Post!]! @hasMany
        tasks: [Task!]! @hasMany
        loud: String @method(name: "loud")
        broken: String @method(name: "broken")
        required: String! @method(name: "nothing")
      }
      type Company { id: ID! name: String strict: String! @method(name: "nothing") }
      type Post { id: ID! title: String comments: [Comment!]! @hasMany }
      type Comment { id: ID! comment: String }
      type Task { id: ID! name: String }
      interface Titled { title: String }
      type Book implements Titled { title: String pages: Int }
      type Movie implements Titled { title: String minutes: Int }
    GRAPHQL
  end

  let(:schema) { build_schema(sdl, dataloader: true).tap { |s| s.use(Lighthouse::GraphQL::Defer) } }
  let(:loud_calls) { [] }

  before do
    calls = loud_calls
    LH::User.define_method(:loud) { (calls << id) && name.upcase }
    LH::User.define_method(:broken) { raise GraphQL::ExecutionError, "no #{name}" }
    LH::User.define_method(:nothing) { nil }
    LH::Company.define_method(:nothing) { nil }
    company = LH::Company.create!(name: 'Acme')
    3.times do |i|
      user = LH::User.create!(name: "u#{i}", company: company)
      post = LH::Post.create!(title: "p#{i}", user: user)
      2.times { |c| LH::Comment.create!(comment: "c#{i}#{c}", post: post) }
      LH::Task.create!(name: "t#{i}", user: user)
    end
  end

  after do
    %i[loud broken nothing].each { |name| LH::User.remove_method(name) }
    LH::Company.remove_method(:nothing)
  end

  def run(query, **options)
    Lighthouse::GraphQL::Incremental::Run.new(schema, query, **options).start
  end

  def payloads(query, **options)
    run(query, **options).then { |run| [].tap { |all| run.each_payload { |payload| all << payload } } }
  end

  def errors(query, **options) = run(query, **options).result['errors']&.pluck('message')

  def pending(*payloads) = payloads.flat_map { |payload| payload['pending'] || [] }

  # The response a client puts together from the payloads: each entry merged at its pending
  # path (and subPath), a stream's items after the list's.
  def assembled(payloads)
    data = payloads.first['data'].deep_dup
    paths = {}
    payloads.each do |payload|
      payload['pending'].to_a.each { |entry| paths[entry['id']] = entry['path'] }
      payload['incremental'].to_a.each { |entry| apply(data, paths.fetch(entry['id']) + entry['subPath'].to_a, entry) }
    end
    data
  end

  def apply(data, path, entry)
    target = path.reduce(data) { |value, key| value[key] }
    entry.key?('items') ? target.concat(entry['items'].deep_dup) : merge_into(target, entry['data'])
  end

  def merge_into(target, data)
    data.each do |key, value|
      if target[key].is_a?(Hash) && value.is_a?(Hash) then merge_into(target[key], value)
      elsif target[key].is_a?(Array) && value.is_a?(Array) then target[key].zip(value).each { |old, new| merge_into(old, new) }
      else target[key] = value.deep_dup
      end
    end
  end

  describe 'the specification draft' do
    it 'answers a query with two deferred fragments as the draft does, both in one round' do
      query = <<~GRAPHQL
        query {
          user(id: 1) {
            ...CompanyFragment @defer(label: "companyDefer")
            name
            posts { ...PostFragment @defer(label: "postDefer") }
          }
        }
        fragment CompanyFragment on User { company { name } }
        fragment PostFragment on Post { title }
      GRAPHQL

      expect(payloads(query)).to eq(
        [
          { 'data' => { 'user' => { 'name' => 'u0', 'posts' => [{}] } },
            'pending' => [
              { 'id' => '0', 'path' => ['user'], 'label' => 'companyDefer' },
              { 'id' => '1', 'path' => ['user', 'posts', 0], 'label' => 'postDefer' }
            ],
            'hasNext' => true },
          { 'incremental' => [{ 'id' => '0', 'data' => { 'company' => { 'name' => 'Acme' } } }, { 'id' => '1', 'data' => { 'title' => 'p0' } }],
            'completed' => [{ 'id' => '0' }, { 'id' => '1' }], 'hasNext' => false }
        ]
      )
    end

    it 'gives a fragment under a list one pending entry for each item, and delivers them together' do
      all = payloads('{ users { name ... @defer { tasks { name } } } }')

      expect(all.first['pending'].pluck('path')).to eq([['users', 0], ['users', 1], ['users', 2]])
      expect(all.last['incremental'].pluck('data')).to eq([{ 'tasks' => [{ 'name' => 't0' }] }, { 'tasks' => [{ 'name' => 't1' }] },
                                                           { 'tasks' => [{ 'name' => 't2' }] }])
      expect(all.last).to include('hasNext' => false, 'completed' => %w[0 1 2].map { |id| { 'id' => id } })
    end

    it 'leaves out the label of a fragment without one' do
      expect(payloads('{ users { ... @defer { name } } }').first['pending'].first.keys).to eq(%w[id path])
    end

    it 'defers a fragment on a type the object does not have to nothing, and runs one it has' do
      all = payloads('{ shelf { title ... on Book @defer(label: "book") { pages } } }')

      expect(all.first['data']).to eq('shelf' => [{ 'title' => 'Dune' }, { 'title' => 'Alien' }, { 'title' => 'Emma' }])
      expect(all.first['pending'].pluck('path')).to eq([['shelf', 0], ['shelf', 2]])
      expect(all.last['incremental'].pluck('data')).to eq([{ 'pages' => 412 }, { 'pages' => 474 }])
    end
  end

  describe 'nesting' do
    let(:query) do
      'query { users { id ... @defer(label: "a") { name posts { title ... @defer(label: "b") { comments { comment } } } } } }'
    end

    it 'announces a fragment inside a deferred one with its parent, and delivers it after' do
      all = payloads(query)

      expect(all.size).to eq(3)
      expect(all[1]['pending'].map { |entry| entry.values_at('id', 'label') }).to eq([%w[3 b], %w[4 b], %w[5 b]])
      expect(all[1]['pending'].first['path']).to eq(['users', 0, 'posts', 0])
      expect(all[1]['completed'].pluck('id')).to eq(%w[0 1 2])
      expect(all[1]['hasNext']).to be(true)
      expect(all[2]['incremental'].first).to eq('id' => '3', 'data' => { 'comments' => [{ 'comment' => 'c00' }, { 'comment' => 'c01' }] })
      expect(all[2]['hasNext']).to be(false)
    end

    it 'announces the fragments each object found, checked against its own data' do
      first = LH::User.first
      LH::Post.where(user: first).find_each { |post| post.comments.delete_all && post.delete }
      LH::Post.create!(title: 'p1b', user: LH::User.second)
      all = payloads('{ users { id ... @defer { posts { id ... @defer { title } } } } }')
      delivered = all.flat_map { |payload| payload['incremental'].to_a }.filter_map { |entry| entry.dig('data', 'title') }

      expect(delivered).to eq(%w[p1 p1b p2])
      expect(pending(*all).pluck('id')).to match_array(all.flat_map { |payload| payload['completed'].to_a }.pluck('id'))
      expect(pending(*all).pluck('path').last(3)).to eq([['users', 1, 'posts', 0], ['users', 1, 'posts', 1], ['users', 2, 'posts', 0]])
    end

    it 'delivers a fragment nested in a deferred one at the same path a round after it' do
      all = payloads(<<~GRAPHQL)
        { user(id: 1) { ... @defer(label: "a") { name ... @defer(label: "b") { loud } } ... @defer(label: "c") { ... @defer(label: "d") { id } } } }
      GRAPHQL

      expect(all.map { |payload| payload['pending'].to_a.pluck('label') }).to eq([%w[a c], %w[b d], []])
      expect(all[1]['incremental']).to eq([{ 'id' => '0', 'data' => { 'name' => 'u0' } }])
      expect(all[1]['completed'].pluck('id')).to eq(%w[0 1])
      expect(all[2]['incremental']).to eq([{ 'id' => '2', 'data' => { 'loud' => 'U0' } }, { 'id' => '3', 'data' => { 'id' => '1' } }])
    end

    it 'costs the queries of the same fragments inline' do
      inline = query.gsub(/ @defer\(label: "\w"\)/, '')
      whole = queries_in { schema.execute(inline) }
      deferred = queries_in { payloads(query) }

      expect(deferred.size).to eq(whole.size)
    end
  end

  describe 'queries' do
    it 'costs the queries of the same query without @defer, however many items the list has' do
      20.times { |i| LH::User.create!(name: "more#{i}").tap { |u| LH::Post.create!(title: 'x', user: u).tap { |p| LH::Comment.create!(comment: 'y', post: p) } } }
      deferred = 'query { users { name ... @defer { posts { title comments { comment } } } } }'
      inline = 'query { users { name ... { posts { title comments { comment } } } } }'

      whole = queries_in { schema.execute(inline) }
      expect(queries_in { payloads(deferred) }.size).to eq(whole.size)
    end

    it 'puts the same data together as the query without @defer' do
      deferred = payloads('query { users { id ... @defer { name company { name } } } }')
      merged = deferred.first['data']['users'].each_with_index.map { |user, i| user.merge(deferred.last['incremental'][i]['data']) }

      expect(merged).to eq(schema.execute('query { users { id name company { name } } }').to_h.dig('data', 'users'))
    end

    it 'reads variables, in the fragment and in `if`' do
      query = 'query($id: ID!, $now: Boolean!) { user(id: $id) { ... @defer(if: $now) { name } } }'

      deferred = payloads(query, variables: { 'id' => 1, 'now' => true })
      whole = payloads(query, variables: { 'id' => 1, 'now' => false })

      expect(deferred.size).to eq(2)
      expect(deferred.last['incremental']).to eq([{ 'id' => '0', 'data' => { 'name' => 'u0' } }])
      expect(whole).to eq([{ 'data' => { 'user' => { 'name' => 'u0' } }, 'pending' => [], 'hasNext' => false }])
    end

    it "parses through the schema's trace, once, a document that does not parse too" do
      parsed = []
      schema.trace_with(Module.new do
        define_method(:parse) do |query_string:, &block|
          (parsed << query_string) && super(query_string: query_string, &block)
        end
      end)
      allow(GraphQL).to receive(:parse).and_call_original

      run('{ users { name } }')
      run('{ users { ... @defer { name } } }')
      run('{ users { ')

      expect(parsed).to eq(['{ users { name } }', '{ users { ... @defer { name } } }', '{ users { '])
      expect(GraphQL).to have_received(:parse).thrice
    end

    it "evaluates the arguments of the document's directives once a request, not again in each unit" do
      calls = 0
      allow_any_instance_of(GraphQL::Query::Partial).to receive(:arguments_for).and_wrap_original do |original, node, definition, **options| # rubocop:disable RSpec/AnyInstance
        calls += 1 if definition == Lighthouse::GraphQL::Incremental::DeferDirective
        original.call(node, definition, **options)
      end

      all = payloads('{ users { ... @defer(label: "a") { posts { ... @defer(label: "b") { title } } } ... @defer(label: "c") { id } } }')

      expect(all.last['incremental'].size).to eq(3)
      # graphql-ruby's own: once for each post the nested fragment is gathered on.
      expect(calls).to eq(LH::Post.count)
    end

    it 'walks a deferred fragment once for the objects it needs, however many objects it is deferred on' do
      walks = lambda do |count|
        LH::User.where.not(id: LH::User.order(:id).limit(count).select(:id)).find_each { |user| user.posts.each(&:delete) && user.delete }
        calls = 0
        allow_any_instance_of(Lighthouse::GraphQL::Incremental::State).to receive(:object_fields).and_wrap_original do |original, *args| # rubocop:disable RSpec/AnyInstance
          (calls += 1) && original.call(*args)
        end
        payloads('{ users { company { name } ... @defer { name company { id } } } }')
        calls
      end

      expect(walks.call(3)).to eq(walks.call(1))
    end

    it "looks the schema's directives up once a request, not once a selection" do
      lookups = lambda do |count|
        LH::User.where.not(id: LH::User.order(:id).limit(count).select(:id)).find_each { |user| user.posts.each(&:delete) && user.delete }
        calls = 0
        allow(schema).to receive(:directives).and_wrap_original do |original|
          caller = caller_locations.find { |location| location.path.exclude?('/rspec-') }
          (calls += 1) if caller.path.include?('/lib/lighthouse/incremental/')
          original.call
        end
        payloads('{ users { ... @defer { name @include(if: true) posts { title @skip(if: false) ... @defer { id } } } } }')
        calls
      end

      expect(lookups.call(3)).to eq(lookups.call(1))
    end

    it "evaluates @skip and @include with the schema's directives looked up once a request" do
      lookups = lambda do |count|
        LH::User.where.not(id: LH::User.order(:id).limit(count).select(:id)).find_each { |user| user.posts.each(&:delete) && user.delete }
        calls = 0
        allow(schema).to receive(:directives).and_wrap_original do |original|
          ours = caller_locations.any? { |location| location.path.include?('/lib/lighthouse/incremental/') && location.path.exclude?('run.rb') }
          (calls += 1) if ours
          original.call
        end
        payloads('{ users { ... @defer { name @include(if: true) posts { title @skip(if: false) ... @defer { id } } } } }')
        calls
      end

      expect(lookups.call(3)).to eq(lookups.call(1))
    end

    it 'checks only the queries whose text may use @defer or @stream, without walking the others' do
      allow(Lighthouse::GraphQL::Incremental::Document).to receive(:incremental?).and_call_original

      schema.execute('{ users { name } }')
      schema.execute(document: GraphQL.parse('{ users { name } }'))

      expect(Lighthouse::GraphQL::Incremental::Document).to have_received(:incremental?).once
    end

    it "builds the operation's query with the schema's query_class, as schema.execute does" do
      query_class = Class.new(GraphQL::Query)
      schema.query_class(query_class)

      expect(run('{ users { ... @defer { name } } }').result.query).to be_a(query_class)
    end

    it 'parses the query once' do
      allow(GraphQL).to receive(:parse).and_call_original

      expect(run('{ users { name } }').result.to_h['data']['users'].size).to eq(3)
      expect(run('{ users { ... @defer { name } } }')).to be_deferred
      expect(GraphQL).to have_received(:parse).twice
    end

    it "runs the client's document as it came: listeners, query_string and the fingerprint see it, streamed or not" do
      query = 'query Names { users { ... @defer(label: "late") { name } } }'
      seen = []
      Lighthouse::Events.listen(Lighthouse::Events::StartExecution) do |event|
        (seen << [event.query.to_query_string, event.graphql_query.then { |q| q.is_a?(GraphQL::Query::Partial) ? q.query : q }]) && nil
      end

      run(query).then { |started| started.each_payload { nil } }
      first = seen.first.last

      expect(seen.map(&:first).uniq).to eq([GraphQL.parse(query).to_query_string])
      expect(first.query_string).to eq(query)
      expect(first.fingerprint).to eq(GraphQL::Query.new(schema, query, operation_name: 'Names').fingerprint)
    end

    it 'runs a fragment with `if: false` where it stands' do
      expect(payloads('{ users { ... @defer(if: false) { name } } }').first['data']['users'].first).to eq('name' => 'u0')
    end

    it 'resolves a field the fragment shares with the rest once' do
      payloads('{ users { loud ... @defer { loud name } } }')

      expect(loud_calls.size).to eq(3)
    end

    # The specification draft's: the fragment is deferred all the same, and completes; what the
    # rest of the query already delivered at its path is neither resolved nor sent again. (Apollo
    # and PHP Lighthouse do not defer such a field at all.)
    describe 'a field asked for outside a @defer too' do
      def completed_only(id) = { 'completed' => [{ 'id' => id }], 'hasNext' => false }

      it 'comes in the first payload, and the fragment completes with nothing left to send' do
        query = <<~GRAPHQL
          { user(id: 1) { ...UserWithCompany ... @defer { company { name } } } }
          fragment UserWithCompany on User { name company { name } }
        GRAPHQL

        expect(payloads(query)).to eq([{ 'data' => { 'user' => { 'name' => 'u0', 'company' => { 'name' => 'Acme' } } },
                                         'pending' => [{ 'id' => '0', 'path' => ['user'] }], 'hasNext' => true },
                                       completed_only('0')])
      end

      it 'is resolved once, whether the @defer sits in a named fragment or an inline one' do
        named = payloads('{ user(id: 1) { loud ...F } } fragment F on User { ... @defer { loud } }')
        inline = payloads('{ user(id: 1) { loud ... @defer { loud } } }')

        expect([named, inline]).to all(eq([{ 'data' => { 'user' => { 'loud' => 'U0' } }, 'pending' => [{ 'id' => '0', 'path' => ['user'] }],
                                             'hasNext' => true }, completed_only('0')]))
        expect(loud_calls).to eq([1, 1])
      end

      it 'sends the rest of the fragment, and the selections it adds to a shared object, at their subPath, resolving it once' do
        query = '{ users { company { name } ... @defer { name company { id } } } }'
        all = nil
        deferred = queries_in { all = payloads(query) }

        expect(all.first['data']['users'].first).to eq('company' => { 'name' => 'Acme' })
        expect(all.last['incremental'].first(2)).to eq([{ 'id' => '0', 'data' => { 'name' => 'u0' } },
                                                        { 'id' => '0', 'subPath' => ['company'], 'data' => { 'id' => '1' } }])
        expect(deferred.size).to eq(queries_in { schema.execute('{ users { company { name } name company { id } } }') }.size)
      end

      describe 'where the app picked its own trace mode, or asked for a backtrace' do
        def fallback(query) = payloads(query, context: { trace_mode: :app_mode })

        it 'resolves a shared object once all the same, and the whole response is the query without the directives' do
          query = '{ user(id: 1) { posts { id } ... @defer { posts { title } } } }'
          started = run(query, context: { trace_mode: :app_mode })
          all = []
          deferred = queries_in { started.each_payload { |payload| all << payload } }
          plain = schema.execute('{ user(id: 1) { posts { id title } } }').to_h['data']

          expect(all.last['incremental']).to eq([{ 'id' => '0', 'subPath' => ['posts', 0], 'data' => { 'title' => 'p0' } }])
          expect([assembled(all), started.response['data']]).to eq([plain, plain])
          expect(deferred).to be_empty
        end

        it "keeps graphql-ruby's backtrace of an error" do
          LH::User.define_method(:loud) { raise 'boom' }

          expect { run('{ users { id ... @defer { name } loud } }', context: { backtrace: true }) }.to raise_error(GraphQL::Backtrace::TracedError)
        end

        it 'does not resolve a shared object again when the fragment adds nothing to it' do
          query = '{ user(id: 1) { company { name } ... @defer { company { name } } } }'
          all = nil
          deferred = queries_in { all = fallback(query) }

          expect(all.last).to eq(completed_only('0'))
          expect(deferred.size).to eq(queries_in { schema.execute('{ user(id: 1) { company { name } } }') }.size)
        end

        it 'gives each item of a list what the fragment adds to it, whatever the first item holds' do
          all = fallback('{ shelf { ... on Book { title } } ... @defer { shelf { title } } }')

          expect(assembled(all)).to eq('shelf' => [{ 'title' => 'Dune' }, { 'title' => 'Alien' }, { 'title' => 'Emma' }])
        end
      end

      it 'adds to the objects of a named fragment spread at several places in the deferred one' do
        query = <<~GRAPHQL
          { a: user(id: 1) { company { id } } b: user(id: 2) { company { id } } c: users { company { id } }
            ... @defer { a: user(id: 1) { ...F } b: user(id: 2) { ... on User { ...F } } c: users { ...F } } }
          fragment F on User { company { name } }
        GRAPHQL
        all = payloads(query)

        expect(all.last['completed']).to eq([{ 'id' => '0' }])
        expect(assembled(all)).to eq(schema.execute(query.gsub(' @defer', '')).to_h['data'])
      end

      it 'is sent once when two fragments of a round share it' do
        all = payloads('{ user(id: 1) { ... @defer(label: "a") { name loud } ... @defer(label: "b") { loud id } } }')

        # Three grouped field sets: a's, the one a and b share (sent under a's id), b's.
        expect(all.last['incremental']).to eq([{ 'id' => '0', 'data' => { 'name' => 'u0' } }, { 'id' => '0', 'data' => { 'loud' => 'U0' } },
                                               { 'id' => '1', 'data' => { 'id' => '1' } }])
        expect(all.last['completed']).to eq([{ 'id' => '0' }, { 'id' => '1' }])
        expect(loud_calls).to eq([1])
      end
    end

    it 'defers a fragment once on an object that gathers it twice' do
      all = payloads('{ user(id: 1) { ...F } user(id: 1) { ...F } } fragment F on User { ... @defer { name } }')

      expect(all.first['pending']).to eq([{ 'id' => '0', 'path' => ['user'] }])
      expect(all.last['incremental']).to eq([{ 'id' => '0', 'data' => { 'name' => 'u0' } }])
    end

    it 'does not skip an @include the fragment is under' do
      all = payloads('query($on: Boolean!) { users { ... @defer @include(if: $on) { name } } }', variables: { 'on' => false })

      expect(all.first['pending']).to eq([])
    end

    it 'defers nothing under a null object' do
      expect(payloads('{ user(id: 99) { ... @defer { name } } }')).to eq([{ 'data' => { 'user' => nil }, 'pending' => [], 'hasNext' => false }])
    end
  end

  describe 'mutations' do
    it 'runs the mutation once, and the deferred fragment on its result' do
      all = payloads('mutation { createUser(name: "zed") { id ... @defer { name company { name } } } }')

      expect(LH::User.where(name: 'zed').count).to eq(1)
      expect(all.first['pending']).to eq([{ 'id' => '0', 'path' => ['createUser'] }])
      expect(all.last['incremental']).to eq([{ 'id' => '0', 'data' => { 'name' => 'zed', 'company' => nil } }])
    end
  end

  describe 'errors' do
    it 'puts the errors of a deferred field on its incremental entry, with the path it has in the response' do
      all = payloads('{ users { ... @defer { name broken } } }')
      entry = all.last['incremental'].first

      expect(entry['data']).to eq('name' => 'u0', 'broken' => nil)
      expect(entry['errors']).to eq([{ 'message' => 'no u0', 'locations' => [{ 'line' => 1, 'column' => 29 }], 'path' => ['users', 0, 'broken'] }])
      expect(all.last['completed'].first).to eq('id' => '0')
    end

    it 'completes a fragment with errors, and no data, when a non-null field fails beyond it' do
      all = payloads('{ users { id ... @defer { name required } } }')

      expect(all.last['incremental']).to be_nil
      expect(all.last['completed'].first['id']).to eq('0')
      expect(all.last['completed'].first['errors'].first).to include('path' => ['users', 0, 'required'])
    end

    it 'puts the errors of the first pass in the first payload' do
      first = payloads('{ users { broken ... @defer { name } } }').first

      expect(first['errors'].first['path']).to eq(['users', 0, 'broken'])
    end

    it 'drops the fragments of an object an error nulled out' do
      all = payloads('{ users { required ... @defer { name } } }')

      expect(all.first['data']).to be_nil
      expect(all.first['pending']).to eq([])
    end

    it 'ends the stream with the failure of a fragment that raised' do
      LH::User.define_method(:loud) { raise 'boom' }
      run = run('{ users { ... @defer { loud } } }')
      all = []

      expect { run.each_payload { |payload| all << payload } }.to raise_error(RuntimeError, 'boom')
      expect(all.last).to eq('completed' => %w[0 1 2].map { |id|
        { 'id' => id, 'errors' => [{ 'message' => 'Internal server error' }] }
      }, 'hasNext' => false)
    end
  end

  describe '@stream' do
    it 'streams the null items of a list of objects as null' do
      all = payloads('{ gaps @stream(initialCount: 0) { name } }')

      expect(all.last['incremental']).to eq([{ 'id' => '0', 'items' => [{ 'name' => 'u0' }, nil, { 'name' => 'u1' }] }])
    end

    it 'fails a stream with a null item where the list has non-null items' do
      all = payloads('{ strictGaps @stream(initialCount: 1) { name } }')

      expect(all.last['incremental']).to be_nil
      message = "Cannot return null for non-nullable element of type 'User!' for Query.strictGaps"
      expect(all.last['completed']).to eq([{ 'id' => '0', 'errors' => [{ 'message' => message, 'path' => ['strictGaps', 1] }] }])
    end

    it 'fails a stream whose non-null item an error nulls' do
      all = payloads('{ users @stream(initialCount: 0) { required } }')

      expect(all.last['incremental']).to be_nil
      expect(all.last['completed'].first['errors'].pluck('path')).to eq((0..2).map { |index| ['users', index, 'required'] })
    end

    it 'leaves out of the later items what a fragment selects when the streamed field is spread both inside it and outside' do
      all = payloads(<<~GRAPHQL)
        { user(id: 1) { ... @defer(label: "a") { required posts { title } ...F } ...F } }
        fragment F on User { posts @stream(initialCount: 0) { id } }
      GRAPHQL

      expect(assembled(all)).to eq('user' => { 'posts' => [{ 'id' => LH::Post.first.id.to_s }] })
    end

    it 'answers the first items at once and the others later, as the draft does' do
      all = payloads('{ users @stream(initialCount: 1, label: "more") { name } }')

      expect(all).to eq(
        [
          { 'data' => { 'users' => [{ 'name' => 'u0' }] }, 'pending' => [{ 'id' => '0', 'path' => ['users'], 'label' => 'more' }],
            'hasNext' => true },
          { 'incremental' => [{ 'id' => '0', 'items' => [{ 'name' => 'u1' }, { 'name' => 'u2' }] }], 'completed' => [{ 'id' => '0' }],
            'hasNext' => false }
        ]
      )
    end

    it 'streams the whole list with the default initialCount of 0' do
      all = payloads('{ users @stream { name } }')

      expect(all.first['data']).to eq('users' => [])
      expect(all.last['incremental'].first['items'].size).to eq(3)
    end

    it 'streams a list of scalars' do
      all = payloads('{ names @stream(initialCount: 2) }')

      expect(all.first['data']).to eq('names' => %w[ann bob])
      expect(all.last['incremental']).to eq([{ 'id' => '0', 'items' => %w[cat dan] }])
    end

    it 'answers a negative initialCount with a field error, streamed or not, as the draft does' do
      query = 'query($count: Int!) { someNames @stream(initialCount: $count) names }'
      error = { 'message' => 'The initialCount of @stream must not be negative.', 'locations' => [{ 'line' => 1, 'column' => 23 }],
                'path' => ['someNames'] }

      answer = { 'data' => { 'someNames' => nil, 'names' => %w[ann bob cat dan] }, 'errors' => [error] }

      expect(payloads(query, variables: { 'count' => -1 }).first).to include(answer)
      expect(schema.execute(query, variables: { 'count' => -1 }).to_h).to eq(answer)
    end

    it 'streams the items with the selections of the streamed field only, not those of another field of the same name' do
      all = payloads('{ users @stream(initialCount: 1) { id } x: users { name } }')

      expect(all.last['incremental']).to eq([{ 'id' => '0', 'items' => [{ 'id' => '2' }, { 'id' => '3' }] }])
    end

    it 'merges the selections of every declaration of the streamed field' do
      all = payloads('{ users @stream(initialCount: 1) { id } ... on Query { users { name } } }')

      expect(all.last['incremental'].first['items']).to eq([{ 'id' => '2', 'name' => 'u1' }, { 'id' => '3', 'name' => 'u2' }])
    end

    it 'answers a list whole where a deferred fragment selects it too, and adds to its items in that fragment' do
      all = payloads('{ users @stream(initialCount: 1) { id } ... @defer { users { name } } }')

      expect(all.first['data']).to eq('users' => [{ 'id' => '1' }, { 'id' => '2' }, { 'id' => '3' }])
      expect(all.first['pending']).to eq([{ 'id' => '0', 'path' => [] }])
      expect(all.last['incremental']).to eq((0..2).map { |i| { 'id' => '0', 'subPath' => ['users', i], 'data' => { 'name' => "u#{i}" } } })
    end

    describe 'with @defer in and around the streamed items' do
      before { LH::User.find_each { |user| LH::Post.create!(title: "q#{user.id}", user: user) } }

      [
        '{ users @stream(initialCount: %d) { name posts { id } ... @defer { posts { title } } } }',
        '{ users @stream(initialCount: %d) { name ... @defer { posts { id ... @defer { title comments { comment } } } } } }',
        '{ users @stream(initialCount: %d) { posts { id } ... @defer { name posts { title ... @defer { comments { comment } } } } } }',
        '{ users @stream(initialCount: %d) { posts { id title } ... @defer { name posts @stream(initialCount: 1) { comments { comment } } } } }'
      ].product([0, 1, 2]).each do |template, count|
        it "puts every value with its own record: #{format(template, count)}" do
          query = format(template, count)
          plain = schema.execute(query.gsub(/ @(defer|stream)(\([^)]*\))?/, '')).to_h['data']

          expect(assembled(payloads(query))).to eq(plain)
        end
      end

      it 'resolves the posts of a streamed item once, the deferred titles from the objects it kept' do
        streamed = queries_in { payloads('{ users @stream(initialCount: 1) { posts { id } ... @defer { posts { title } } } }') }

        expect(streamed.size).to eq(queries_in { payloads('{ users @stream(initialCount: 1) { posts { id title } } }') }.size)
      end
    end

    describe 'on a lazy list' do
      let(:sdl) { super().sub('type Query {', 'type Query { later: [String!]! @field(resolver: "DeferSpecLater")') }

      before { schema.lazy_resolve(DeferSpecLazy, :value) }

      it 'cuts each alias where its own @stream says' do
        all = payloads('{ a: later @stream(initialCount: 1) b: later @stream(initialCount: 3) c: later }')

        expect(all.first['data']).to eq('a' => %w[ann], 'b' => %w[ann bob cat], 'c' => %w[ann bob cat dan])
        expect(all.last['incremental']).to contain_exactly({ 'id' => '0', 'items' => %w[bob cat dan] }, { 'id' => '1', 'items' => %w[dan] })
      end
    end

    it 'streams the field that carries @stream, and no other' do
      all = payloads('{ names @stream(initialCount: 1) someNames shelf { title } }')

      expect(all.first['data']).to eq('names' => %w[ann], 'someNames' => %w[ann bob cat dan],
                                      'shelf' => [{ 'title' => 'Dune' }, { 'title' => 'Alien' }, { 'title' => 'Emma' }])
      expect(all.last['incremental']).to eq([{ 'id' => '0', 'items' => %w[bob cat dan] }])
    end

    it 'changes no field: the schema that uses the plugin streams, and no other built on the same types' do
      base = build_schema(sdl, dataloader: true)
      streaming = Class.new(base) { use Lighthouse::GraphQL::Defer }
      field = base.get_field('Query', 'users')

      expect([field.extensions, field.extras]).to eq([[], []])
      expect(streaming.trace_modules_for(:default)).to include(Lighthouse::GraphQL::Incremental::StreamTrace)
      expect(base.trace_modules_for(:default)).not_to include(Lighthouse::GraphQL::Incremental::StreamTrace)
    end

    it 'streams a list field defined after the schema used the plugin' do
      schema.query.field(:later_names, [String], null: false)
      schema.query.define_method(:later_names) { %w[x y z] }

      all = payloads('{ laterNames @stream(initialCount: 1) }')

      expect(all.first['data']).to eq('laterNames' => %w[x])
      expect(all.last['incremental']).to eq([{ 'id' => '0', 'items' => %w[y z] }])
    end

    it 'answers null for a nullable list that resolves to null, as without @stream' do
      expect(payloads('{ maybe @stream(initialCount: 1) }')).to eq([{ 'data' => { 'maybe' => nil }, 'pending' => [], 'hasNext' => false }])
    end

    it 'answers the whole list when it is shorter than initialCount, or the stream is off' do
      expect(payloads('{ names @stream(initialCount: 4) }').first).to include('data' => { 'names' => %w[ann bob cat dan] }, 'pending' => [])
      expect(payloads('{ names @stream(initialCount: 1, if: false) }').first['data']).to eq('names' => %w[ann bob cat dan])
    end

    it 'costs the queries of the list without @stream, however long it is' do
      stream = 'query { users @stream(initialCount: 1) { name posts { title comments { comment } } } }'
      whole = queries_in { schema.execute('query { users { name posts { title comments { comment } } } }') }

      # The first item loads its posts and comments on its own, the others together.
      expect(queries_in { payloads(stream) }.size).to eq(whole.size + 2)
    end

    it 'defers a fragment inside the streamed items, and numbers their paths from the list' do
      all = payloads('{ users @stream(initialCount: 1) { name ... @defer(label: "t") { tasks { name } } } }')
      tasks = all.flat_map { |payload| payload['incremental'].to_a }.filter_map { |entry| entry['data'] }

      expect(all.first['pending'].pluck('path')).to eq([['users'], ['users', 0]])
      expect(all[1]['pending'].pluck('path')).to eq([['users', 1], ['users', 2]])
      expect(all[1]['incremental'].first['items']).to eq([{ 'name' => 'u1' }, { 'name' => 'u2' }])
      expect(tasks).to eq([{ 'tasks' => [{ 'name' => 't0' }] }, { 'tasks' => [{ 'name' => 't1' }] }, { 'tasks' => [{ 'name' => 't2' }] }])
    end

    it 'puts an error of a streamed item at the position the item has in the list' do
      all = payloads('{ users @stream(initialCount: 1) { name broken } }')

      expect(all.last['incremental'].first['errors'].pluck('path')).to eq([['users', 1, 'broken'], ['users', 2, 'broken']])
    end

    it 'refuses @stream on a field that is not a list' do
      expect(errors('{ user(id: 1) @stream { name } }')).to eq(['The @stream directive must be used on a list field.'])
    end
  end

  describe 'a client that does not stream' do
    it 'gets the whole response from schema.execute, as a JSON client does' do
      result = schema.execute('{ users { name ... @defer { company { name } } } }')

      expect(result.to_h.dig('data', 'users').first).to eq('name' => 'u0', 'company' => { 'name' => 'Acme' })
    end
  end

  describe 'limits' do
    let(:query) do
      '{ users { id ... @defer(label: "a") { name posts { id ... @defer(label: "b") { title ... @defer(label: "c") { comments { comment } } } } } } }'
    end
    let(:labels) { ->(all) { all.map { |payload| payload['pending'].to_a.pluck('label').uniq } } }

    it 'goes in rounds, a payload each, a round for each level of nesting, without a limit' do
      all = payloads(query)

      expect(labels.call(all)).to eq([%w[a], %w[b], %w[c], []])
      expect(all.last['incremental'].first['data']).to eq('comments' => [{ 'comment' => 'c00' }, { 'comment' => 'c01' }])
    end

    it 'resolves what is left in the last round allowed by defer_max_nested_fields, as PHP Lighthouse' do
      Lighthouse.configure { |c| c.defer_max_nested_fields = 2 }

      all = payloads(query)

      expect(labels.call(all)).to eq([%w[a], %w[b], []])
      expect(all.last['incremental'].first['data']).to eq('title' => 'p0', 'comments' => [{ 'comment' => 'c00' }, { 'comment' => 'c01' }])
      expect(all.last['hasNext']).to be(false)
    end

    it 'resolves it all in the first round with defer_max_nested_fields 1' do
      Lighthouse.configure { |c| c.defer_max_nested_fields = 1 }

      all = payloads('{ users @stream(initialCount: 1) { name ... @defer { posts { title ... @defer { id } } } } }')

      expect(all.size).to eq(2)
      expect(all.last['incremental'].first['items'])
        .to eq([{ 'name' => 'u1', 'posts' => [{ 'title' => 'p1', 'id' => '2' }] }, { 'name' => 'u2', 'posts' => [{ 'title' => 'p2', 'id' => '3' }] }])
    end

    it 'resolves what is left in the next round once defer_max_execution_ms have gone, as PHP Lighthouse' do
      Lighthouse.configure { |c| c.defer_max_execution_ms = 1 }
      LH::User.define_method(:loud) { (sleep(0.002) || true) && name }

      all = payloads(query.sub('{ id ...', '{ loud ...'))

      expect(labels.call(all)).to eq([%w[a], []])
      comments = [{ 'comment' => 'c00' }, { 'comment' => 'c01' }]
      expect(all.last['incremental'].first['data']['posts']).to eq([{ 'id' => '1', 'title' => 'p0', 'comments' => comments }])
    end

    it 'has no limit by default' do
      expect([Lighthouse::Config.defer_max_nested_fields, Lighthouse::Config.defer_max_execution_ms]).to eq([0, 0])
    end

    it 'takes a limit from the environment, a String of digits, as its number' do
      Lighthouse.configure do |config|
        config.defer_max_nested_fields = '2'
        config.defer_max_execution_ms = ' 1500 '
      end

      expect([Lighthouse::Config.defer_max_nested_fields, Lighthouse::Config.defer_max_execution_ms]).to eq([2, 1500])
      expect(payloads('{ user(id: 1) { ... @defer { name } } }').size).to eq(2)
    end

    it 'refuses a limit that is not a number of 0 or more when it is set, not when a request runs' do
      ['many', -1, 1.5, '-3', ''].each do |value|
        expect { Lighthouse.configure { |config| config.defer_max_execution_ms = value } }
          .to raise_error(ArgumentError, "Lighthouse::Config.defer_max_execution_ms must be an Integer of 0 or more, got #{value.inspect}.")
      end
      expect { Lighthouse::Config.defer_max_nested_fields = 'x' }.to raise_error(ArgumentError, /defer_max_nested_fields/)
    end
  end

  describe 'the rules of the specification' do
    it 'refuses a label two fragments share' do
      message = 'The label "x" is used by more than one @defer or @stream in the document.'

      expect(errors('{ users { ... @defer(label: "x") { name } ... @defer(label: "x") { id } } }')).to eq([message])
    end

    it 'takes a label that is null, as no label' do
      all = payloads('{ users { id ... @defer(label: null) { name } } }')

      expect(all.first['errors']).to be_nil
      expect(all.first['pending'].first).to eq('id' => '0', 'path' => ['users', 0])
      expect(schema.execute('{ users { id ... @defer(label: null) { name } } }').to_h['errors']).to be_nil
    end

    it 'refuses a label that is a variable' do
      message = 'The label of @defer must be a String literal, not a variable.'

      expect(errors('query($l: String) { users { ... @defer(label: $l) { name } } }')).to eq([message])
    end

    it 'refuses @defer on a root mutation field, whose fields run in turn, in PHP Lighthouse\'s words' do
      message = 'The @defer directive cannot be used on a root mutation field.'

      expect(errors('mutation { ... @defer { createUser(name: "a") { id } } }')).to eq([message])
      expect(LH::User.where(name: 'a')).to be_empty
    end

    it 'refuses @defer on a root mutation field in a named fragment, and runs no mutation' do
      query = <<~GRAPHQL
        mutation { ...M }
        fragment M on Mutation { a: createUser(name: "x") { id } ... @defer { b: createUser(name: "y") { id } } }
      GRAPHQL

      expect(errors(query)).to eq(['The @defer directive cannot be used on a root mutation field.'])
      expect(errors('mutation { ...M @defer } fragment M on Mutation { createUser(name: "y") { id } }'))
        .to eq(['The @defer directive cannot be used on a root mutation field.'])
      expect(errors('mutation { createUser(name: "y") { ...U } } fragment U on User { ... @defer { name } }')).to be_nil
      expect(LH::User.where(name: %w[x y]).count).to eq(1)
    end

    it 'refuses @stream on a root mutation field' do
      expect(errors('mutation { createUser(name: "a") @stream { id } }'))
        .to eq(['The @stream directive cannot be used on a root mutation field.', 'The @stream directive must be used on a list field.'])
    end

    describe 'in a subscription' do
      let(:schema) do
        build_schema("#{sdl}\ntype Subscription { userCreated: User }", dataloader: true).tap { |s| s.use(Lighthouse::GraphQL::Defer) }
      end
      let(:message) { 'The @defer directive must be disabled with `if: false` in a subscription.' }

      # What the analysis answers, as the subscription is not run (the schema has no subscriptions).
      def analysis(query, variables: {})
        GraphQL::Analysis.analyze_query(GraphQL::Query.new(schema, query, variables: variables), schema.query_analyzers).flatten.map(&:message)
      end

      it 'refuses @defer unless it is disabled' do
        expect(analysis('subscription { userCreated { ... @defer { name } } }')).to eq([message])
        expect(analysis('subscription { userCreated { ... @defer(if: false) { name } } }')).to eq([])
        expect(analysis('subscription($d: Boolean!) { userCreated { ... @defer(if: $d) { name } } }', variables: { 'd' => false })).to eq([])
      end

      it 'refuses @defer and @stream whose `if` is a variable that is true, as the draft forbids incremental delivery there' do
        query = 'subscription($d: Boolean!) { userCreated { ... @defer(if: $d) { name } posts @stream(if: $d) { id } } }'

        expect(analysis(query, variables: { 'd' => true }))
          .to eq([message, 'The @stream directive must be disabled with `if: false` in a subscription.'])
      end

      it "looks the schema's directives up once a request, not once a directive" do
        calls = 0
        allow(schema).to receive(:directives).and_wrap_original do |original|
          (calls += 1) if caller_locations.any? { |location| location.path.include?('/lib/lighthouse/incremental/') }
          original.call
        end
        analysis('subscription { userCreated { ... @defer(if: false) { name } ... @defer(if: false) { id } posts @stream(if: false) { id } } }')

        expect(calls).to eq(2)
      end

      it 'refuses it in a named fragment the subscription spreads' do
        expect(analysis('subscription { ...S } fragment S on Subscription { userCreated { ... @defer { name } } }')).to eq([message])
      end
    end

    it "judges the client's document when streamed, as when not" do
      [
        'mutation { createUser(name: "z") { id posts @stream { id } } ... @defer { createUser(name: "z") { id } } }',
        '{ user(id: 1) { name ... @defer(label: "x") { name } ... @defer(label: "x") { id } } }'
      ].each do |query|
        expect(errors(query)).to eq(schema.execute(query).to_h['errors'].pluck('message'))
      end
      expect(LH::User.where(name: 'z')).to be_empty
    end

    it 'refuses a label two directives share anywhere in the document, not only in the operation that runs' do
      query = 'query A { users { ... @defer(label: "x") { name } } } query B { users { ... @defer(label: "x") { id } } }'

      expect(errors(query, operation_name: 'A')).to eq(['The label "x" is used by more than one @defer or @stream in the document.'])
    end

    it 'checks every query, however it runs: plain, streamed, and in a batch' do
      query = '{ users { ... @defer(label: "x") { name } ... @defer(label: "x") { id } } }'
      message = 'The label "x" is used by more than one @defer or @stream in the document.'

      expect(schema.execute(query).to_h).to eq('errors' => [{ 'message' => message, 'locations' => [{ 'line' => 1, 'column' => 47 }] }])
      expect(errors(query)).to eq([message])
      expect(schema.multiplex([{ query: query }, { query: '{ names }' }]).map { |result| result.to_h['errors']&.pluck('message') })
        .to eq([[message], nil])
    end

    it 'answers a request without a query as graphql-ruby does' do
      expect(run(nil).result.to_h).to eq(schema.execute(nil).to_h)
    end

    it 'leaves a query that does not parse to graphql-ruby' do
      parse_errors = schema.execute('{ users { ')['errors'].pluck('message')

      expect(errors('{ users { ')).to eq(parse_errors)
    end

    it 'counts the deferred fragments in the complexity of the query' do
      schema.complexity_cost_calculation_mode(:future)
      schema.max_complexity(3)

      expect(errors('{ users { name ... @defer { company { name } } } }')).to eq(['Query has complexity of 4, which exceeds max complexity of 3'])
    end
  end

  describe 'the schema' do
    it 'needs graphql-ruby 2.5.23, whose runtime gives each list item its own path' do
      stub_const('GraphQL::VERSION', '2.5.22')

      expect { build_schema(sdl).use(Lighthouse::GraphQL::Defer) }
        .to raise_error(Lighthouse::DefinitionError, /needs graphql-ruby 2\.5\.23 or newer/)
    end

    it 'has the directive only when it uses the plugin' do
      expect(build_schema(sdl, dataloader: true).directives).not_to have_key('defer')
      expect(schema.directives['defer']).to eq(Lighthouse::GraphQL::Incremental::DeferDirective)
      expect(Lighthouse::GraphQL::Defer.enabled?(schema)).to be(true)
    end

    it 'prints the directive as the specification declares it' do
      printed = schema.to_definition.gsub(/"""[^"]*"""\s*/m, '').gsub(/\s+/, ' ')

      expect(printed).to include('directive @defer( if: Boolean! = true label: String ) on FRAGMENT_SPREAD | INLINE_FRAGMENT')
    end

    it 'does not answer the directive to a query that does not name it' do
      result = build_schema(sdl, dataloader: true).execute('{ users { ... @defer { name } } }')

      expect(result.to_h['errors'].first['message']).to include('Directive @defer is not defined')
    end
  end

  describe 'events' do
    it 'dispatches the execution events for the first pass and for each object a fragment runs on, with the operation' do
      seen = []
      Lighthouse::Events.listen(Lighthouse::Events::StartExecution) { |event| (seen << [:start, event.operation_name]) && nil }
      Lighthouse::Events.listen(Lighthouse::Events::EndExecution) { |event| (seen << [:end, event.result.keys]) && nil }

      payloads('query Names { users { ... @defer { name } } }')

      expect(seen.map(&:first)).to eq(%i[start end] + (%i[start] * 3) + (%i[end] * 3))
      expect(seen.map(&:last).uniq).to eq(['Names', ['data']])
    end
  end

  describe 'the delivery of a fragment' do
    it 'is all or nothing: a fragment one of whose parts fails beyond its root sends no data, and completes with the errors' do
      all = payloads('{ user(id: 1) { company { name } ... @defer { name company { strict } } } }')

      expect(all.last['incremental']).to be_nil
      expect(all.last['completed'].first['errors'].pluck('path')).to eq([%w[user company strict]])
    end

    it 'fails a fragment for its own units only: one that shares a field with a fragment that fails still sends it' do
      all = payloads('{ user(id: 1) { id ... @defer(label: "b") { name required } } ... @defer(label: "a") { user(id: 1) { name } } }')
      ids = all.first['pending'].to_h { |entry| [entry['label'], entry['id']] }

      expect(all.last['incremental']).to eq([{ 'id' => ids['a'], 'subPath' => ['user'], 'data' => { 'name' => 'u0' } }])
      expect(all.last['completed'].find { |entry| entry['id'] == ids['a'] }).to eq('id' => ids['a'])
      expect(all.last['completed'].find { |entry| entry['id'] == ids['b'] }['errors'].pluck('path')).to eq([%w[user required]])
    end

    it "sends a fragment's fields when another fragment at its path fails" do
      all = payloads('{ user(id: 1) { ... @defer(label: "a") { name } ... @defer(label: "b") { required } } }')

      expect(all.last['incremental']).to eq([{ 'id' => '0', 'data' => { 'name' => 'u0' } }])
      expect(all.last['completed']).to match([{ 'id' => '0' }, { 'id' => '1', 'errors' => [hash_including('path' => %w[user required])] }])
    end

    it 'sends none of what a fragment that fails adds to an object field it shares with one that does not' do
      all = payloads('{ user(id: 1) { ... @defer(label: "a") { required company { name } } ... @defer(label: "b") { company { id } } } }')

      expect(assembled(all)).to eq('user' => { 'company' => { 'id' => LH::Company.first.id.to_s } })
      expect(all.last['completed'].map { |entry| [entry['id'], entry['errors']&.pluck('path')] }).to eq([['0', [%w[user required]]], ['1', nil]])
    end

    it 'fails only the fragment whose field of a shared object nulls it' do
      all = payloads('{ user(id: 1) { ... @defer(label: "a") { company { strict } } ... @defer(label: "b") { company { name } } } }')

      expect(assembled(all)).to eq('user' => { 'company' => { 'name' => 'Acme' } })
      expect(all.last['completed'].find { |entry| entry['id'] == '0' }['errors'].pluck('path')).to eq([%w[user company strict]])
    end

    it 'delivers the fragment nested in one that does not fail, beside one that does' do
      all = payloads('{ user(id: 1) { ... @defer(label: "a") { required } ... @defer(label: "b") { name ... @defer(label: "c") { loud } } } }')

      expect(pending(*all).pluck('label')).to eq(%w[a b c])
      expect(assembled(all)).to eq('user' => { 'name' => 'u0', 'loud' => 'U0' })
    end

    it 'announces the fragments a unit that carries no data found' do
      all = payloads('{ user(id: 1) { ... @defer(label: "a") { ... @mark { ... @defer(label: "b") { name } } } } }')

      expect(pending(*all).pluck('label')).to eq(%w[a b])
      expect(assembled(all)).to eq('user' => { 'name' => 'u0' })
    end

    it 'sends no entry that carries nothing: its extensions go on the payload' do
      allow_any_instance_of(Lighthouse::GraphQL::Incremental::Run).to receive(:run).and_wrap_original do |original, partials| # rubocop:disable RSpec/AnyInstance
        original.call(partials).map { |response| response.merge('data' => {}, 'extensions' => { 'seen' => true }) }
      end

      later = payloads('{ user(id: 1) { company { name } ... @defer { name company { id } } } }').last

      expect(later['incremental']).to be_nil
      expect(later['extensions']).to eq('seen' => true)
      expect(later['completed']).to eq([{ 'id' => '0' }])
    end
  end

  describe 'a failure in a later round' do
    # A controller whose response is on its way once the first payload is written, as
    # ActionController::Live's is: it has performed, and can render nothing more.
    let(:controller) do
      Class.new do
        attr_reader :cache_store, :notes
        attr_writer :committed

        def initialize = (@cache_store = ActiveSupport::Cache::MemoryStore.new) && (@notes = [])
        def controller_path = 'graphql'
        def request = nil
        def performed? = @committed || false
        def head(*) = raise(ActionDispatch::IllegalStateError, 'header already sent')

        private

        def note_it = @notes << :limited
      end.new
    end

    it 'ends the stream when a later payload cannot be written, completing every id the client was sent' do
      run = run('{ users { ... @defer(label: "a") { name posts { ... @defer(label: "b") { title } } } } }')
      all = []
      failed = false
      write = lambda do |payload|
        if all.size == 2 && !failed
          failed = true
          raise IOError, 'cannot encode'
        end
        all << payload
      end

      expect { run.each_payload(&write) }.to raise_error(IOError, 'cannot encode')
      expect(all.last).to eq('completed' => %w[3 4 5].map { |id| { 'id' => id, 'errors' => [{ 'message' => 'Internal server error' }] } },
                             'hasNext' => false)
    end

    def streamed(query)
      run = run(query, context: { lighthouse_controller: controller, remote_ip: '10.0.0.1' })
      [].tap { |all| run.each_payload { |payload| (all << payload) && (controller.committed = true) } }
    end

    it 'answers a @throttle past its limit with a field error, where the response can no longer be refused' do
      stub_const('ActionDispatch::IllegalStateError', Class.new(StandardError)) unless defined?(ActionDispatch::IllegalStateError)
      all = streamed('{ ... @defer { limited noted } }')
      entry = all.last['incremental'].first

      expect(entry['data']).to eq('limited' => nil, 'noted' => nil)
      expect(entry['errors'].pluck('message')).to eq(['Rate limit for Query.limited exceeded. Try again later.',
                                                      'Rate limit for Query.noted exceeded. Try again later.'])
      expect(all.last).to include('completed' => [{ 'id' => '0' }], 'hasNext' => false)
      expect(controller.notes).to eq([])
    end

    it 'completes only the ids the client was sent' do
      calls = 0
      allow(Lighthouse::GraphQL::Incremental::Serializer).to receive(:subsequent).and_wrap_original do |original, **payload|
        raise 'boom' if payload[:pending].any? && (calls += 1) == 1

        original.call(**payload)
      end
      run = run('{ users { ... @defer(label: "a") { name posts { ... @defer(label: "b") { title } } } } }')
      all = []

      expect { run.each_payload { |payload| all << payload } }.to raise_error(RuntimeError, 'boom')
      expect(all.last['completed'].pluck('id')).to eq(%w[0 1 2])
    end
  end

  describe 'extensions' do
    before do
      Lighthouse::Events.listen(Lighthouse::Events::BuildExtensionsResponse) do |event|
        data = event.result['data']
        Lighthouse::Events::ExtensionsResponse.new('ran', data.is_a?(Array) ? 'items' : data&.keys || 'nothing')
      end
    end

    it 'delivers the extensions of a fragment\'s run on its incremental entry, and the first pass\'s on the first payload' do
      all = payloads('{ users { id ... @defer { name } } }')

      expect(all.first['extensions']).to eq('ran' => ['users'])
      expect(all.last['incremental'].pluck('extensions')).to eq([{ 'ran' => ['name'] }] * 3)
    end

    it "reports the operation's complexity once, with the first pass, and not again with each unit" do
      scores = []
      Lighthouse::Events.listen(Lighthouse::Events::BuildExtensionsResponse) { |event| (scores << event.query_complexity) && nil }

      payloads('{ users { id ... @defer { name } } }')

      expect(scores.first).to be_a(Integer)
      expect(scores.drop(1)).to eq([nil] * 3)
    end

    it 'delivers those of streamed items on their entry' do
      expect(payloads('{ names @stream(initialCount: 1) }').last['incremental'].first['extensions']).to eq('ran' => 'items')
    end

    it 'delivers those of a fragment that leaves no data on the payload' do
      later = payloads('{ users { id ... @defer { name required } } }').last

      expect(later['incremental']).to be_nil
      expect(later['extensions']).to eq('ran' => 'nothing')
    end
  end

  describe 'the multiplexes of a streamed response' do
    it "runs each round in a multiplex of its own trace and dataloader, and leaves the app's context hash as it was" do
      multiplexes = []
      schema.trace_with(Module.new do
        define_method(:execute_multiplex) do |multiplex:, &block|
          (multiplexes << multiplex) && super(multiplex: multiplex, &block)
        end
      end)
      context = { current_user: :someone }

      all = payloads('{ users { ... @defer(label: "a") { name posts { ... @defer(label: "b") { title } } } } }', context: context)

      expect(all.size).to eq(3)
      expect(multiplexes.map { |multiplex| multiplex.current_trace.object_id }.uniq.size).to eq(3)
      expect(multiplexes.map { |multiplex| multiplex.dataloader.object_id }.uniq.size).to eq(3)
      expect(context).to eq(current_user: :someone)
    end
  end

  describe 'the data a streamed response keeps' do
    it 'copies none of the first payload but the containers later data goes in, and changes no payload' do
      started = run('{ users { id company { name } ... @defer { name } } }')
      all = []
      started.each_payload { |payload| all << payload }
      first = all.first['data']['users'].first
      whole = started.response['data']['users'].first

      expect(first).to eq('id' => '1', 'company' => { 'name' => 'Acme' })
      expect(all.last['incremental'].first).to eq('id' => '0', 'data' => { 'name' => 'u0' })
      expect(whole).to eq('id' => '1', 'company' => { 'name' => 'Acme' }, 'name' => 'u0')
      expect(whole['company']).to equal(first['company'])
    end
  end

  describe 'the operation events of a streamed response' do
    let(:ended) { [] }

    before { Lighthouse::Events.listen(Lighthouse::Events::EndOperationOrOperations) { |event| (ended << event.result_or_results) && nil } }

    def incremental(query, &block) = Lighthouse::GraphQL::PersistedQueries.incremental(schema, query: query, &block)

    it 'ends the operation after the last round, with the data and the errors of every round' do
      log = []
      incremental('{ user(id: 1) { id ... @defer { name broken } } }') do |run|
        run.each_payload { |payload| log << [payload['hasNext'], ended.size] }
      end

      expect(log).to eq([[true, 0], [false, 0]])
      expect(ended.last.to_h['data']).to eq('user' => { 'id' => '1', 'name' => 'u0', 'broken' => nil })
      expect(ended.last.to_h['errors'].pluck('message', 'path')).to eq([['no u0', %w[user broken]]])
    end

    it 'ends one that defers nothing at once, with its result, as schema.execute' do
      result = incremental('{ user(id: 1) { id } }') { |run| [run.result, ended.dup] }

      expect(result).to eq([ended.first, [ended.first]])
    end

    it 'ends one the block never streams, once the block is done, with what it holds' do
      incremental('{ user(id: 1) { id ... @defer { name } } }') { |run| expect(run).to be_deferred }

      expect(ended.map { |response| response.to_h['data'] }).to eq([{ 'user' => { 'id' => '1' } }])
    end

    it 'ends one whose client left with what was sent, and writes nothing more, nor any error of its own' do
      gone = Class.new(Lighthouse::GraphQL::Incremental::Gone)
      written = []
      expect do
        incremental('{ users { id ... @defer(label: "a") { name posts { ... @defer(label: "b") { title } } } } }') do |run|
          run.each_payload { |payload| written.size == 1 ? raise(gone) : written << payload }
        end
      end.to raise_error(gone)

      expect(written.size).to eq(1)
      expect(ended.last.to_h).to eq('data' => { 'users' => [{ 'id' => '1' }, { 'id' => '2' }, { 'id' => '3' }] })
    end

    it 'ends one with a protocol error at once, with that error' do
      Lighthouse.configure { |config| config.persisted_queries = true }

      result = Lighthouse::GraphQL::PersistedQueries.incremental(schema, query: nil, extensions: { 'persistedQuery' => { 'version' => 1, 'sha256Hash' => 'a' * 64 } }) { raise 'not run' }

      expect(ended).to eq([result])
    end

    it "ends one once, and lets through a protocol error the block raises after its run ended, which is not the request's" do
      error = Lighthouse::GraphQL::PersistedQueries::Error.new('raised by the app', 'APP')

      expect { incremental('{ user(id: 1) { id } }') { raise error } }.to raise_error(error)
      expect(ended.size).to eq(1)
      streamed = lambda do |run|
        run.each_payload { nil }
        raise error
      end
      expect { incremental('{ user(id: 1) { id ... @defer { name } } }', &streamed) }.to raise_error(error)
      expect(ended.size).to eq(2)
    end

    it "ends schema.execute's operation once when a listener of its end raises a protocol error" do
      error = Lighthouse::GraphQL::PersistedQueries::Error.new('raised by a listener', 'LISTENER')
      Lighthouse::Events.listen(Lighthouse::Events::EndOperationOrOperations) { raise error }

      expect { Lighthouse::GraphQL::PersistedQueries.execute(schema, query: '{ user(id: 1) { id } }') }.to raise_error(error)
      expect(ended.size).to eq(1)
    end

    it 'lets through an error a listener of its start raises, and runs nothing' do
      error = Lighthouse::GraphQL::PersistedQueries::Error.new('raised by a listener', 'LISTENER')
      Lighthouse::Events.listen(Lighthouse::Events::StartOperationOrOperations) { raise error }

      expect { incremental('{ user(id: 1) { id } }') { raise 'not run' } }.to raise_error(error)
      expect { Lighthouse::GraphQL::PersistedQueries.execute(schema, query: '{ user(id: 1) { id } }') }.to raise_error(error)
      expect(ended).to eq([])
    end
  end

  describe Lighthouse::GraphQL::Defer do
    it 'streams to a client that accepts multipart/mixed, in this gem\'s format' do
      expect(described_class.stream_type('multipart/mixed;incrementalSpec=v0.2,application/json')).not_to be_nil
      expect(described_class.stream_type('multipart/mixed')).not_to be_nil
      expect(described_class.stream_type('multipart/mixed;deferSpec=20220824,application/json')).to be_nil
      expect(described_class.stream_type('application/json')).to be_nil
      expect(described_class.stream_type(nil)).to be_nil
    end

    it 'honours q-values: never multipart/mixed at q=0, nor below a JSON type the client prefers' do
      expect(described_class.stream_type('application/json, multipart/mixed;q=0')).to be_nil
      expect(described_class.stream_type('multipart/mixed;q=0.5, application/json')).to be_nil
      expect(described_class.stream_type('multipart/mixed;q=0.5, application/graphql-response+json;q=0.8')).to be_nil
      expect(described_class.stream_type('application/json;q=0.9, multipart/mixed;q=0.95')).not_to be_nil
      apollo = 'multipart/mixed;incrementalSpec=v0.2, application/graphql-response+json, application/json;q=0.9'
      expect(described_class.stream_type(apollo)).not_to be_nil
      expect(described_class.stream_type('application/json, multipart/mixed')).to be_nil
      expect(described_class.stream_type('multipart/mixed;q=0')).to be_nil
    end

    it 'names the format in the content type when the client did' do
      expect(described_class.stream_type('multipart/mixed;incrementalSpec=v0.2')).to eq('multipart/mixed; boundary="-"; incrementalSpec=v0.2')
      expect(described_class.stream_type('multipart/mixed')).to eq('multipart/mixed; boundary="-"')
    end
  end

  describe Lighthouse::GraphQL::Incremental::Tree do
    it 'walks a response path, in Hashes and lists, to nil where it leads nowhere' do
      data = { 'users' => [{ 'posts' => [{ 'title' => 'p0' }] }, nil] }

      expect(described_class.at(data, ['users', 0, 'posts', 0, 'title'])).to eq('p0')
      expect([described_class.at(data, ['users', 1, 'posts']), described_class.at(data, %w[users posts]), described_class.at(nil, ['users'])])
        .to eq([nil, nil, nil])
      expect(described_class.at(data, [])).to equal(data)
    end
  end

  describe Lighthouse::GraphQL::Incremental::Multipart do
    it 'writes the parts of a multipart/mixed body, each ending with the boundary that opens the next' do
      stream = StringIO.new
      multipart = described_class.new(stream)

      multipart.emit(multipart.part('a' => 1))
      expect(stream.string).to eq("\r\n---\r\nContent-Type: application/json; charset=utf-8\r\n\r\n{\"a\":1}\r\n---")
      multipart.emit(multipart.part('b' => 2))
      multipart.finish

      expect(stream.string).to eq(
        "\r\n---\r\nContent-Type: application/json; charset=utf-8\r\n\r\n{\"a\":1}" \
        "\r\n---\r\nContent-Type: application/json; charset=utf-8\r\n\r\n{\"b\":2}\r\n-----\r\n"
      )
    end

    it 'encodes a part as `render json:` encodes a response, so the Accept header does not change a value' do
      stream = StringIO.new
      payload = { 'data' => { 'at' => Time.utc(2026, 1, 2, 3, 4, 5), 'price' => BigDecimal('1.50') } }

      described_class.new(stream).then { |multipart| multipart.emit(multipart.part(payload)) }

      expect(stream.string).to include("\r\n\r\n#{ActiveSupport::JSON.encode(payload)}\r\n---")
      expect(stream.string).to include('"at":"2026-01-02T03:04:05.000Z"', '"price":"1.5"')
    end

    it 'sets the headers that keep proxies and Rack from buffering' do
      expect(described_class.headers).to include('Cache-Control' => 'no-cache', 'X-Accel-Buffering' => 'no',
                                                 'Content-Type' => 'multipart/mixed; boundary="-"')
      expect(described_class.headers).to have_key('Last-Modified')
    end
  end
end
