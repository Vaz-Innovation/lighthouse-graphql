# frozen_string_literal: true

# PHP Lighthouse's @mock: a field answers what the example gave it, and counts its calls.
class DeferPhpMock
  class << self
    attr_accessor :value, :calls

    def call(*)
      self.calls += 1
      value.respond_to?(:call) ? value.call : value
    end
  end
end

# A second @mock (`@mock(key: "...")` in PHP Lighthouse), for one field of the example.
class DeferPhpOther < DeferPhpMock; end

# PHP Lighthouse's tests of @defer (tests/Integration/Defer: DeferTest, DeferIncludeSkipTest,
# DeferDBTest), ported. PHP Lighthouse puts @defer on a field (`parent @defer { name }`), which the
# specification draft does not have: each query here asks for the same field in a deferred
# fragment (`... @defer { parent { name } }`). And PHP Lighthouse answers the 2018 Apollo format
# (a `null` for the deferred field first, then `{ "user.parent": { "data": ... } }` chunks), where
# this answers the draft's: the first payload leaves the field out, and the fragment's data comes
# under the `id` its `pending` entry gave, at the path of the object it runs on. The expectations
# are PHP Lighthouse's, in that format; where the behaviour differs on purpose, a comment says so.
RSpec.describe 'Deferring fields, as PHP Lighthouse tests it' do
  include_context 'with PHP Lighthouse models'

  let(:schema) { build_schema(sdl, dataloader: true).tap { |built| built.use(Lighthouse::GraphQL::Defer) } }

  before do
    [DeferPhpMock, DeferPhpOther].each { |mock| (mock.calls = 0) && (mock.value = nil) }
  end

  # PHP Lighthouse's streamGraphQL: every payload of the response, as the client gets them.
  def stream(query, variables: {})
    run = Lighthouse::GraphQL::Incremental::Run.new(schema, query, variables: variables).start
    [].tap { |payloads| run.each_payload { |payload| payloads << payload } }
  end

  # PHP Lighthouse's graphQL: the response of a client that does not stream.
  def graphql(query, variables = {}) = schema.execute(query, variables: variables).to_h

  # The data each payload delivers, by the path of the object its fragment ran on (as PHP
  # Lighthouse's chunks key them), and the first payload's data under 'data'.
  def chunks(payloads)
    paths = payloads.flat_map { |payload| payload['pending'].to_a }.to_h { |entry| [entry['id'], entry['path'].join('.')] }
    [{ 'data' => payloads.first['data'] }] + payloads.drop(1).map do |payload|
      payload['incremental'].to_a.to_h { |entry| [paths.fetch(entry['id']), entry.except('id')] }
    end
  end

  describe 'DeferTest' do
    let(:sdl) do
      <<~GRAPHQL
        type User {
          name: String!
          parent: User
        }

        type Query {
          user: User @field(resolver: "DeferPhpMock")
        }

        type Mutation {
          updateUser(name: String!): User @field(resolver: "DeferPhpMock")
        }
      GRAPHQL
    end
    let(:nested) { { 'name' => 'John Doe', 'parent' => { 'name' => 'Jane Doe', 'parent' => { 'name' => 'Mr. Smith' } } } }

    it 'adds the defer client directive (testAddsTheDeferClientDirective)' do
      names = graphql('query IntrospectionQuery { __schema { directives { name } } }').dig('data', '__schema', 'directives').pluck('name')

      expect(names).to include('defer')
    end

    it 'defers fields (testDeferFields)' do
      DeferPhpMock.value = { 'name' => 'John Doe', 'parent' => { 'name' => 'Jane Doe' } }

      # PHP Lighthouse: user { name parent @defer { name } }, first answered `parent: null`.
      payloads = stream('{ user { name ... @defer { parent { name } } } }')

      expect(chunks(payloads)).to eq([{ 'data' => { 'user' => { 'name' => 'John Doe' } } },
                                      { 'user' => { 'data' => { 'parent' => { 'name' => 'Jane Doe' } } } }])
      expect(payloads.last['hasNext']).to be(false)
    end

    it 'defers nested fields (testDeferNestedFields)' do
      DeferPhpMock.value = nested

      payloads = stream('{ user { name ... @defer { parent { name ... @defer { parent { name } } } } } }')

      expect(payloads.size).to eq(3)
      expect(chunks(payloads)).to eq([{ 'data' => { 'user' => { 'name' => 'John Doe' } } },
                                      { 'user' => { 'data' => { 'parent' => { 'name' => 'Jane Doe' } } } },
                                      { 'user.parent' => { 'data' => { 'parent' => { 'name' => 'Mr. Smith' } } } }])
    end

    it 'defers nested fields on mutations, and runs the mutation once (testDeferNestedFieldsOnMutations)' do
      DeferPhpMock.value = { 'name' => 'John Doe', 'parent' => { 'name' => 'Jane Doe' } }

      payloads = stream('mutation { updateUser(name: "Foo") { name ... @defer { parent { name } } } }')

      expect(chunks(payloads)).to eq([{ 'data' => { 'updateUser' => { 'name' => 'John Doe' } } },
                                      { 'updateUser' => { 'data' => { 'parent' => { 'name' => 'Jane Doe' } } } }])
      # PHP Lighthouse runs the whole operation again for each round, the mutation too.
      expect(DeferPhpMock.calls).to eq(1)
    end

    describe 'lists' do
      let(:sdl) do
        <<~GRAPHQL
          type Comment { message: String }
          type Post { title: String author: User comments: [Comment] }
          type User { name: String! }
          type Query { posts: [Post] @field(resolver: "DeferPhpMock") }
        GRAPHQL
      end
      let(:data) do
        [{ 'title' => 'Foo', 'author' => { 'name' => 'John Doe' }, 'comments' => [{ 'message' => 'foobar' }] },
         { 'title' => 'Bar', 'author' => { 'name' => 'Jane Doe' }, 'comments' => [{ 'message' => 'foobar' }] }]
      end

      before { DeferPhpMock.value = data }

      it 'defers list fields (testDeferListFields)' do
        payloads = stream('{ posts { title ... @defer { author { name } } } }')

        expect(payloads.size).to eq(2)
        expect(payloads.first['data']['posts']).to eq([{ 'title' => 'Foo' }, { 'title' => 'Bar' }])
        expect(chunks(payloads).last).to eq('posts.0' => { 'data' => { 'author' => { 'name' => 'John Doe' } } },
                                            'posts.1' => { 'data' => { 'author' => { 'name' => 'Jane Doe' } } })
      end

      it 'delivers the fragments of one round together (testDeferGroupedListFields)' do
        # Two fields, each deferred on its own in PHP Lighthouse: two fragments here, one round.
        payloads = stream('{ posts { title ... @defer { author { name } } ... @defer { comments { message } } } }')

        expect(payloads.size).to eq(2)
        expect(payloads.last['incremental'].pluck('data')).to eq(
          [{ 'author' => { 'name' => 'John Doe' } }, { 'comments' => [{ 'message' => 'foobar' }] },
           { 'author' => { 'name' => 'Jane Doe' } }, { 'comments' => [{ 'message' => 'foobar' }] }]
        )
        expect(payloads.first['pending'].pluck('path')).to eq([['posts', 0], ['posts', 0], ['posts', 1], ['posts', 1]])
      end
    end

    it 'cancels deferment after the max execution time (testCancelsDefermentAfterMaxExecutionTime)' do
      # PHP Lighthouse's test sets the deadline to now; here, 1 ms, which the first pass outlasts.
      Lighthouse.configure { |c| c.defer_max_execution_ms = 1 }
      DeferPhpMock.value = lambda do
        sleep(0.005)
        nested
      end

      payloads = stream('{ user { name ... @defer { parent { name ... @defer { parent { name } } } } } }')

      # Without the limit, 3 payloads.
      expect(payloads.size).to eq(2)
      expect(chunks(payloads).last).to eq('user' => { 'data' => { 'parent' => { 'name' => 'Jane Doe', 'parent' => { 'name' => 'Mr. Smith' } } } })
    end

    it 'cancels deferment after max nested fields (testCancelsDefermentAfterMaxNestedFields)' do
      Lighthouse.configure { |c| c.defer_max_nested_fields = 1 }
      DeferPhpMock.value = nested

      payloads = stream('{ user { name ... @defer { parent { name ... @defer { parent { name } } } } } }')

      expect(payloads.size).to eq(2)
      expect(payloads.first['data']).to eq('user' => { 'name' => 'John Doe' })
      expect(chunks(payloads).last).to eq('user' => { 'data' => { 'parent' => { 'name' => 'Jane Doe', 'parent' => { 'name' => 'Mr. Smith' } } } })
    end

    describe 'a Non-Null field (testThrowsExceptionOnNunNullableFields)' do
      let(:sdl) do
        <<~GRAPHQL
          type User { name: String! parent: User! }
          type Query { user: User @field(resolver: "DeferPhpMock") }
        GRAPHQL
      end

      # PHP Lighthouse refuses it ("The @defer directive cannot be used on a Non-Nullable field."),
      # as it answers `null` for a deferred field first. The draft leaves a deferred field out of the
      # first payload instead, so a Non-Null field defers like any other.
      it 'defers it, where PHP Lighthouse refuses' do
        DeferPhpMock.value = { 'name' => 'John Doe', 'parent' => { 'name' => 'Jane Doe' } }

        payloads = stream('{ user { name ... @defer { parent { name } } } }')

        expect(chunks(payloads).last).to eq('user' => { 'data' => { 'parent' => { 'name' => 'Jane Doe' } } })
      end
    end

    describe 'with @include and @skip (testDoesNotDeferWithIncludeAndSkipDirectives)' do
      let(:sdl) do
        <<~GRAPHQL
          type User { name: String! parent: User @field(resolver: "DeferPhpOther") }
          type Query { user: User @field(resolver: "DeferPhpMock") }
        GRAPHQL
      end

      before { DeferPhpMock.value = { 'name' => 'John Doe' } }

      it 'neither defers nor resolves what they leave out' do
        expect(stream('{ user { name ... @defer @include(if: false) { parent { name } } } }'))
          .to eq([{ 'data' => { 'user' => { 'name' => 'John Doe' } }, 'pending' => [], 'hasNext' => false }])

        query = <<~GRAPHQL
          query ($include: Boolean!, $skip: Boolean!) {
            userInclude: user { name ... @defer @include(if: false) { parent { name } } }
            userIncludeVariable: user { name ... @defer @include(if: $include) { parent { name } } }
            userSkip: user { name ... @defer @skip(if: true) { parent { name } } }
            userSkipVariable: user { name ... @defer @skip(if: $skip) { parent { name } } }
          }
        GRAPHQL
        user = { 'name' => 'John Doe' }

        expect(stream(query, variables: { 'include' => false, 'skip' => true })).to eq(
          [{ 'data' => { 'userInclude' => user, 'userIncludeVariable' => user, 'userSkip' => user, 'userSkipVariable' => user },
             'pending' => [], 'hasNext' => false }]
        )
        expect(DeferPhpOther.calls).to eq(0)
      end
    end

    it 'requires @defer on every declaration of a field (testRequiresDeferDirectiveOnAllFieldDeclarations)' do
      DeferPhpMock.value = { 'name' => 'John Doe', 'parent' => { 'name' => 'Jane Doe' } }
      query = <<~GRAPHQL
        fragment UserWithParent on User { name parent { name } }
        query { user { ...UserWithParent ... @defer { parent { name } } } }
      GRAPHQL

      expect(graphql(query)).to eq('data' => { 'user' => DeferPhpMock.value })
      expect(stream(query)).to eq([{ 'data' => { 'user' => DeferPhpMock.value }, 'pending' => [], 'hasNext' => false }])
    end

    describe 'a root mutation field (testThrowsIfTryingToDeferRootMutationFields)' do
      it 'is refused, and the mutation does not run' do
        error = 'The @defer directive cannot be used on a root mutation field.'

        expect(graphql('mutation UpdateUser { ... @defer { updateUser(name: "John Doe") { name } } }')['errors'].pluck('message')).to eq([error])
        expect(stream('mutation UpdateUser { ... @defer { updateUser(name: "John Doe") { name } } }').first['errors'].pluck('message')).to eq([error])
        expect(DeferPhpMock.calls).to eq(0)
      end
    end

    it 'does not defer fields if false (testDoesNotDeferFieldsIfFalse)' do
      DeferPhpMock.value = { 'name' => 'John Doe', 'parent' => { 'name' => 'Jane Doe' } }

      expect(stream('{ user { name ... @defer(if: false) { parent { name } } } }'))
        .to eq([{ 'data' => { 'user' => DeferPhpMock.value }, 'pending' => [], 'hasNext' => false }])
    end

    describe 'errors (testIncludesErrorsForDeferredFields)' do
      let(:sdl) do
        <<~GRAPHQL
          type User { name: String! parent: User @field(resolver: "DeferPhpOther") }
          type Query { user: User @field(resolver: "DeferPhpMock") }
        GRAPHQL
      end

      it 'delivers the errors of a deferred field with it' do
        DeferPhpMock.value = { 'name' => 'John Doe' }
        DeferPhpOther.value = -> { raise GraphQL::ExecutionError, 'deferred_exception' }

        payloads = stream('{ user { name ... @defer { parent { name } } } }')
        parent = chunks(payloads).last['user']

        expect(payloads.size).to eq(2)
        expect(payloads.first).not_to have_key('errors')
        expect(parent['data']).to eq('parent' => nil)
        expect(parent['errors'].size).to eq(1)
        expect(parent['errors'].first).to include('message' => 'deferred_exception', 'path' => %w[user parent])
      end
    end
  end

  describe 'DeferIncludeSkipTest' do
    let(:sdl) { 'type Query { foo: Int @field(resolver: "DeferPhpMock") }' }

    before { DeferPhpMock.value = 1 }

    # PHP Lighthouse: `foo @defer @include(if: false)`; the fragment carries both directives here.
    it 'does not defer with include false (testDoesNotDeferWithIncludeFalse)' do
      expect(graphql('{ ... @defer @include(if: false) { foo } }')).to eq('data' => {})
      expect(stream('{ ... @defer @include(if: false) { foo } }')).to eq([{ 'data' => {}, 'pending' => [], 'hasNext' => false }])
    end

    it 'defers with include true (testDoesDeferWithIncludeTrue)' do
      expect(stream('{ ... @defer @include(if: true) { foo } }').size).to eq(2)
    end

    it 'does not defer with include false from a variable (testDoesNotDeferWithIncludeFalseFromVariable)' do
      query = 'query ($include: Boolean!) { ... @defer @include(if: $include) { foo } }'

      expect(graphql(query, { 'include' => false })).to eq('data' => {})
      expect(stream(query, variables: { 'include' => false }).size).to eq(1)
    end

    it 'does not defer with skip true (testDoesNotDeferWithSkipTrue)' do
      expect(graphql('{ ... @defer @skip(if: true) { foo } }')).to eq('data' => {})
      expect(stream('{ ... @defer @skip(if: true) { foo } }').size).to eq(1)
    end

    it 'defers with skip false (testDoesDeferWithSkipFalse)' do
      expect(stream('{ ... @defer @skip(if: false) { foo } }').size).to eq(2)
    end

    it 'does not defer with skip true from a variable (testDoesNotDeferWithSkipTrueFromVariable)' do
      query = 'query ($skip: Boolean!) { ... @defer @skip(if: $skip) { foo } }'

      expect(graphql(query, { 'skip' => true })).to eq('data' => {})
      expect(stream(query, variables: { 'skip' => true }).size).to eq(1)
    end
  end

  # PHP Lighthouse counts the queries of the whole stream, the rounds after the first included:
  # each round is one query, however many objects it runs on.
  describe 'DeferDBTest' do
    let(:sdl) do
      <<~GRAPHQL
        type Company {
          name: String!
          users: [User] @hasMany
        }

        type User {
          email: String!
          company: Company @belongsTo
        }

        type Query {
          user: User @field(resolver: "DeferPhpMock")
          companies: [Company] @field(resolver: "DeferPhpMock")
        }
      GRAPHQL
    end

    it 'defers belongsTo fields (testDeferBelongsToFields)' do
      company = LH::Company.create!(name: 'Acme')
      DeferPhpMock.value = LH::User.create!(email: 'a@example.com', company: company).tap(&:reload)
      payloads = nil

      expect(queries_in { payloads = stream('{ user { email ... @defer { company { name } } } }') }.size).to eq(1)
      expect(payloads.size).to eq(2)
      expect(chunks(payloads)).to eq([{ 'data' => { 'user' => { 'email' => 'a@example.com' } } },
                                      { 'user' => { 'data' => { 'company' => { 'name' => 'Acme' } } } }])
    end

    it 'defers nested relationship fields (testDeferNestedRelationshipFields)' do
      company = LH::Company.create!(name: 'Acme')
      users = Array.new(5) { |i| LH::User.create!(email: "u#{i}@example.com", company: company) }
      DeferPhpMock.value = users.first.tap(&:reload)
      payloads = nil

      expect(queries_in { payloads = stream('{ user { email ... @defer { company { name ... @defer { users { email } } } } } }') }.size).to eq(2)
      expect(payloads.size).to eq(3)
      expect(chunks(payloads)[1]).to eq('user' => { 'data' => { 'company' => { 'name' => 'Acme' } } })
      expect(chunks(payloads)[2]).to eq('user.company' => { 'data' => { 'users' => users.map { |user| { 'email' => user.email } } } })
    end

    it 'defers nested list fields, one query a round (testDeferNestedListFields)' do
      companies = Array.new(2) do |c|
        LH::Company.create!(name: "Company #{c}").tap do |company|
          3.times { |u| LH::User.create!(email: "c#{c}u#{u}@example.com", company: company) }
        end
      end
      DeferPhpMock.value = LH::Company.where(id: companies.map(&:id)).to_a
      payloads = nil

      sql = queries_in { payloads = stream('{ companies { name ... @defer { users { email ... @defer { company { name } } } } } }') }

      # PHP Lighthouse counts 2: the users of both companies, then the company of all six users.
      # Active Record sets each user's company from the has_many that loaded it (its inverse),
      # so the last round costs none: the users' query is the only one.
      expect(sql.size).to eq(1)
      expect(payloads.size).to eq(3)
      expect(payloads.first['data']['companies']).to eq([{ 'name' => 'Company 0' }, { 'name' => 'Company 1' }])
      expect(chunks(payloads)[1].keys).to eq(%w[companies.0 companies.1])
      expect(chunks(payloads)[1]['companies.0']).to eq('data' => { 'users' => (0..2).map { |u| { 'email' => "c0u#{u}@example.com" } } })
      expect(chunks(payloads)[2].size).to eq(6)
      expect(chunks(payloads)[2].values.map { |item| item['data']['company']['name'] }).to all(be_in(['Company 0', 'Company 1']))
    end
  end
end
