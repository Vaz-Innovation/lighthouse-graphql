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

class DeferSpecNothing
  def self.call(*) = nil
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
      }
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
      type Company { id: ID! name: String }
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
    company = LH::Company.create!(name: 'Acme')
    3.times do |i|
      user = LH::User.create!(name: "u#{i}", company: company)
      post = LH::Post.create!(title: "p#{i}", user: user)
      2.times { |c| LH::Comment.create!(comment: "c#{i}#{c}", post: post) }
      LH::Task.create!(name: "t#{i}", user: user)
    end
  end

  after { %i[loud broken nothing].each { |name| LH::User.remove_method(name) } }

  def run(query, **options)
    Lighthouse::GraphQL::Incremental::Run.new(schema, query, **options).start
  end

  def payloads(query, **options)
    run(query, **options).then { |run| [].tap { |all| run.each_payload { |payload| all << payload } } }
  end

  def errors(query, **options) = run(query, **options).result['errors']&.pluck('message')

  def pending(*payloads) = payloads.flat_map { |payload| payload['pending'] || [] }

  describe 'the specification draft' do
    it 'answers a query with two deferred fragments as the draft does' do
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
          { 'incremental' => [{ 'id' => '0', 'data' => { 'company' => { 'name' => 'Acme' } } }],
            'completed' => [{ 'id' => '0' }], 'hasNext' => true },
          { 'incremental' => [{ 'id' => '1', 'data' => { 'title' => 'p0' } }],
            'completed' => [{ 'id' => '1' }], 'hasNext' => false }
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

    it 'runs a fragment with `if: false` where it stands' do
      expect(payloads('{ users { ... @defer(if: false) { name } } }').first['data']['users'].first).to eq('name' => 'u0')
    end

    it 'resolves a field the fragment shares with the rest once' do
      payloads('{ users { loud ... @defer { loud name } } }')

      expect(loud_calls.size).to eq(3)
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

    it 'streams the field that carries @stream, and no other' do
      all = payloads('{ names @stream(initialCount: 1) someNames shelf { title } }')

      expect(all.first['data']).to eq('names' => %w[ann], 'someNames' => %w[ann bob cat dan],
                                      'shelf' => [{ 'title' => 'Dune' }, { 'title' => 'Alien' }, { 'title' => 'Emma' }])
      expect(all.last['incremental']).to eq([{ 'id' => '0', 'items' => %w[bob cat dan] }])
    end

    it 'adds no extras to the list fields it extends, which would cost every list resolved' do
      field = schema.get_field('Query', 'users')

      expect(field.extensions.map(&:class)).to include(Lighthouse::GraphQL::Incremental::StreamExtension)
      expect(field.extras).to be_empty
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
    it 'gets the whole response' do
      result = run('{ users { name ... @defer { company { name } } } }', stream: false).result

      expect(result.to_h.dig('data', 'users').first).to eq('name' => 'u0', 'company' => { 'name' => 'Acme' })
    end

    it 'runs the whole response through graphql-ruby when the schema is used without the controller' do
      expect(schema.execute('{ users { name ... @defer { company { name } } } }').to_h.dig('data', 'users', 0, 'company')).to eq('name' => 'Acme')
    end
  end

  describe 'limits' do
    it 'runs the fragments past defer_max_pending where they stand' do
      Lighthouse.configure { |c| c.defer_max_pending = 2 }

      all = payloads('{ users { ... @defer { name } } }')

      expect(all.first['pending'].size).to eq(2)
      expect(all.first['data']['users'].last).to eq('name' => 'u2')
    end
  end

  describe 'the rules of the specification' do
    it 'refuses a label two fragments share' do
      message = 'The label "x" is used by more than one @defer or @stream in the document.'

      expect(errors('{ users { ... @defer(label: "x") { name } ... @defer(label: "x") { id } } }')).to eq([message])
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
      def analysis(query)
        GraphQL::Analysis.analyze_query(GraphQL::Query.new(schema, query), schema.query_analyzers).flatten.map(&:message)
      end

      it 'refuses @defer unless it is disabled' do
        expect(analysis('subscription { userCreated { ... @defer { name } } }')).to eq([message])
        expect(analysis('subscription { userCreated { ... @defer(if: false) { name } } }')).to eq([])
        expect(analysis('subscription($d: Boolean!) { userCreated { ... @defer(if: $d) { name } } }')).to eq([])
      end

      it 'refuses it in a named fragment the subscription spreads' do
        expect(analysis('subscription { ...S } fragment S on Subscription { userCreated { ... @defer { name } } }')).to eq([message])
      end
    end

    it 'checks every query, however it runs: plain, unstreamed, and in a batch' do
      query = '{ users { ... @defer(label: "x") { name } ... @defer(label: "x") { id } } }'
      message = 'The label "x" is used by more than one @defer or @stream in the document.'

      expect(schema.execute(query).to_h).to eq('errors' => [{ 'message' => message, 'locations' => [{ 'line' => 1, 'column' => 47 }] }])
      expect(errors(query, stream: false)).to eq([message])
      expect(schema.multiplex([{ query: query }, { query: '{ names }' }]).map { |result| result.to_h['errors']&.pluck('message') })
        .to eq([[message], nil])
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

    it 'delivers those of streamed items on their entry' do
      expect(payloads('{ names @stream(initialCount: 1) }').last['incremental'].first['extensions']).to eq('ran' => 'items')
    end

    it 'delivers those of a fragment that leaves no data on the payload' do
      later = payloads('{ users { id ... @defer { name required } } }').last

      expect(later['incremental']).to be_nil
      expect(later['extensions']).to eq('ran' => 'nothing')
    end
  end

  describe Lighthouse::GraphQL::Defer do
    it 'streams to a client that accepts multipart/mixed, in this gem\'s format' do
      expect(described_class.accepts?('multipart/mixed;incrementalSpec=v0.2,application/json')).to be(true)
      expect(described_class.accepts?('multipart/mixed')).to be(true)
      expect(described_class.accepts?('multipart/mixed;deferSpec=20220824,application/json')).to be(false)
      expect(described_class.accepts?('application/json')).to be(false)
      expect(described_class.accepts?(nil)).to be(false)
    end

    it 'names the format in the content type when the client did' do
      expect(described_class.content_type('multipart/mixed;incrementalSpec=v0.2')).to eq('multipart/mixed; boundary="-"; incrementalSpec=v0.2')
      expect(described_class.content_type('multipart/mixed')).to eq('multipart/mixed; boundary="-"')
    end
  end

  describe Lighthouse::GraphQL::Incremental::Multipart do
    it 'writes the parts of a multipart/mixed body, each ending with the boundary that opens the next' do
      stream = StringIO.new
      multipart = described_class.new(stream)

      multipart.write('a' => 1)
      expect(stream.string).to eq("\r\n---\r\nContent-Type: application/json; charset=utf-8\r\n\r\n{\"a\":1}\r\n---")
      multipart.write('b' => 2)
      multipart.finish

      expect(stream.string).to eq(
        "\r\n---\r\nContent-Type: application/json; charset=utf-8\r\n\r\n{\"a\":1}" \
        "\r\n---\r\nContent-Type: application/json; charset=utf-8\r\n\r\n{\"b\":2}\r\n-----\r\n"
      )
    end

    it 'encodes a part as `render json:` encodes a response, so the Accept header does not change a value' do
      stream = StringIO.new
      payload = { 'data' => { 'at' => Time.utc(2026, 1, 2, 3, 4, 5), 'price' => BigDecimal('1.50') } }

      described_class.new(stream).write(payload)

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
