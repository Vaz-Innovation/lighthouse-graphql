# frozen_string_literal: true

# Field that returns a fixed string (for @guard).
class AuthSpecConst
  def self.call(_obj, _args, _ctx)
    'ok'
  end
end

# Resolves a post by id, without authorizing anything itself.
class AuthSpecFindPost
  def self.call(_obj, args, _ctx)
    Post.find_by(id: args[:id])
  end
end

# Resolves no posts.
class AuthSpecNoPosts
  def self.call(_obj, _args, _ctx) = []
end

# Users are hashes: { role: :admin | :writer | :reader, level: Integer }.
class PostPolicy
  attr_reader :user, :record

  def initialize(user, record)
    @user = user || {}
    @record = record
  end

  def show? = admin? || record.published
  def create? = %i[admin writer].include?(user[:role])
  def read_body? = admin?

  # injectArgs: true passes the field's arguments first.
  def publish?(args) = admin? && args[:title] != 'forbidden'

  # args: 2 passes the static value.
  def edit?(minimum_level) = user.fetch(:level, 0) >= minimum_level

  private

  def admin? = user[:role] == :admin
end

RSpec.describe 'Authorization directives (@guard and the @can* family)' do
  let(:sdl) do
    <<~GRAPHQL
      type Query {
        secret: String @field(resolver: "AuthSpecConst") @guard

        post(id: ID! @eq): Post @find @canResolved(ability: "show")
        postCount(title: String @eq): Int @count(model: "Post") @canQuery(ability: "show")
        publishedCount(title: String @eq): Int @count(model: "Post") @canQuery(ability: "show", scopes: ["published"])
        foundPost(id: ID!): Post @field(resolver: "AuthSpecFindPost") @canFind(ability: "show", find: "id")
        lenientPost(id: ID!): Post
          @field(resolver: "AuthSpecFindPost") @canFind(ability: "show", find: "id", findOrFail: false)
        concealedPost(id: ID!): Post
          @field(resolver: "AuthSpecFindPost") @canFind(ability: "show", find: "id", action: EXCEPTION_NOT_AUTHORIZED)
        fallbackTitle(id: ID!): String
          @field(resolver: "AuthSpecFindPost") @canFind(ability: "show", find: "id", model: "Post", action: RETURN_VALUE, returnValue: "hidden")
        misspeltPath(id: ID!): Post @field(resolver: "AuthSpecFindPost") @canFind(ability: "show", find: "input.id")
        optionalId(id: ID): Post @field(resolver: "AuthSpecFindPost") @canFind(ability: "show", find: "id")
        eachPost(inputs: [EditPostInput!]!): [Post!]! @field(resolver: "AuthSpecNoPosts") @canFind(ability: "show", find: "inputs.*.id", model: "Post")
      }

      type Mutation {
        createPost(title: String!): Post @create @canModel(ability: "create")
        publishPost(id: ID!, title: String): Post @update @canFind(ability: "publish", find: "id", injectArgs: true)
        editPost(input: EditPostInput! @spread): Post @update @canFind(ability: "edit", find: "input.id", args: 2)
        guardedCreate(title: String!): Post @create @canModel(ability: "create") @guard
      }

      input EditPostInput {
        id: ID!
        title: String
      }

      type Post {
        id: ID!
        title: String
        body: String @canRoot(ability: "read_body")
      }
    GRAPHQL
  end

  let(:schema) { build_schema(sdl, dataloader: true) }
  let(:admin) { { role: :admin } }
  let(:reader) { { role: :reader } }
  let!(:draft) { Post.create!(title: 'Draft', body: 'draft body') }
  let!(:live) { Post.create!(title: 'Live', body: 'live body', published: true) }

  before do
    Lighthouse.configure do |c|
      c.authenticated_user = ->(ctx) { ctx[:current_user] }
      c.policy_user = ->(ctx) { ctx[:current_user] }
    end
  end

  def run(query, user = nil)
    schema.execute(query, context: { current_user: user }).to_h
  end

  def messages(result)
    (result['errors'] || []).map { |e| e['message'] }
  end

  describe '@guard' do
    it 'rejects an unauthenticated request' do
      result = run('{ secret }')
      expect(result.dig('data', 'secret')).to be_nil
      expect(messages(result)).to eq(['Unauthenticated.'])
    end

    it 'allows an authenticated request' do
      expect(run('{ secret }', reader)).to eq('data' => { 'secret' => 'ok' })
    end

    it 'runs before the @can* checks' do
      result = run('mutation { guardedCreate(title: "x") { id } }')
      expect(messages(result)).to eq(['Unauthenticated.'])
    end
  end

  describe '@canResolved' do
    it 'authorizes the record the field resolved to' do
      expect(run("{ post(id: #{live.id}) { title } }", reader)).to eq('data' => { 'post' => { 'title' => 'Live' } })
      expect(messages(run("{ post(id: #{draft.id}) { title } }", reader))).to eq(['This action is unauthorized.'])
    end

    it 'lets a null result through' do
      expect(run('{ post(id: 0) { title } }', reader)).to eq('data' => { 'post' => nil })
    end
  end

  describe '@canQuery' do
    it 'authorizes every record the field arguments select' do
      expect(run('{ postCount(title: "Live") }', reader)).to eq('data' => { 'postCount' => 1 })
      expect(messages(run('{ postCount }', reader))).to eq(['This action is unauthorized.'])
      expect(run('{ postCount }', admin)).to eq('data' => { 'postCount' => 2 })
    end

    it 'applies its scopes to the records it authorizes, not to what the field resolves' do
      # Only the published post is checked, so the reader passes; @count still counts both.
      expect(run('{ publishedCount }', reader)).to eq('data' => { 'publishedCount' => 2 })
    end
  end

  describe '@canFind' do
    it 'authorizes the models an argument identifies before resolving' do
      expect(run("{ foundPost(id: #{live.id}) { title } }", reader)).to eq('data' => { 'foundPost' => { 'title' => 'Live' } })
      expect(messages(run("{ foundPost(id: #{draft.id}) { title } }", reader))).to eq(['This action is unauthorized.'])
    end

    it 'fails when a model is not found, unless findOrFail is false' do
      expect(messages(run('{ foundPost(id: 999) { title } }', admin))).to eq(["Couldn't find Post with 'id'=999"])
      expect(run('{ lenientPost(id: 999) { title } }', admin)).to eq('data' => { 'lenientPost' => nil })
    end

    it 'follows a dot path into an input, and passes static args to the policy' do
      query = %(mutation { editPost(input: { id: #{draft.id}, title: "Edited" }) { title } })

      expect(messages(run(query, { level: 1 }))).to eq(['This action is unauthorized.'])
      expect(run(query, { level: 2 })).to eq('data' => { 'editPost' => { 'title' => 'Edited' } })
    end

    it 'passes the field arguments to the policy with injectArgs' do
      expect(run(%(mutation { publishPost(id: #{draft.id}, title: "forbidden") { title } }), admin)['errors']).not_to be_nil
      expect(run(%(mutation { publishPost(id: #{draft.id}, title: "Fine") { title } }), admin))
        .to eq('data' => { 'publishPost' => { 'title' => 'Fine' } })
    end

    it 'conceals the real error with action: EXCEPTION_NOT_AUTHORIZED' do
      expect(messages(run('{ concealedPost(id: 999) { title } }', admin))).to eq(['This action is unauthorized.'])
    end

    it 'returns returnValue instead with action: RETURN_VALUE' do
      expect(run("{ fallbackTitle(id: #{draft.id}) }", reader)).to eq('data' => { 'fallbackTitle' => 'hidden' })
    end

    it 'fails, not passes unchecked, when nothing is at the find: path' do
      result = run("{ misspeltPath(id: #{draft.id}) { title } }", reader)

      expect(result['data']).to eq('misspeltPath' => nil)
      expect(messages(result)).to eq(['Got no key to find a model at the expected input path: input.id.'])
      expect(messages(run('{ optionalId { title } }', reader))).to eq(['Got no key to find a model at the expected input path: id.'])
    end

    it 'checks no model for a * over an empty list' do
      expect(run('{ eachPost(inputs: []) { id } }', reader)).to eq('data' => { 'eachPost' => [] })
      expect(messages(run("{ eachPost(inputs: [{ id: #{draft.id} }]) { id } }", reader))).to eq(['This action is unauthorized.'])
    end
  end

  describe '@canModel' do
    it 'authorizes against the model class before the mutation runs' do
      expect(messages(run('mutation { createPost(title: "New") { id } }', reader))).to eq(['This action is unauthorized.'])
      expect(Post.count).to eq(2)

      expect(run('mutation { createPost(title: "New") { title } }', { role: :writer }))
        .to eq('data' => { 'createPost' => { 'title' => 'New' } })
    end
  end

  describe '@canRoot' do
    it 'authorizes the parent object' do
      result = run("{ post(id: #{live.id}) { title body } }", reader)
      expect(result.dig('data', 'post')).to eq('title' => 'Live', 'body' => nil)
      expect(messages(result)).to eq(['This action is unauthorized.'])

      expect(run("{ post(id: #{live.id}) { body } }", admin)).to eq('data' => { 'post' => { 'body' => 'live body' } })
    end
  end

  it 'injects the @can* definitions and their CanAction / CanArgs types' do
    injected = Lighthouse::GraphQL::SchemaGenerator.inject_directive_definitions(sdl)

    expect(injected).to include(*%w[guard canFind canModel canQuery canResolved canRoot].map { |name| "directive @#{name}" })
    expect(injected).to include('enum CanAction', 'scalar CanArgs')
  end

  it 'no longer provides @can, which the @can* family replaces' do
    expect { build_schema('type Query { a: String @can(ability: "x") }') }
      .to raise_error(Lighthouse::DefinitionError, 'No directive found for `@can` on Query.a.')
  end
end
