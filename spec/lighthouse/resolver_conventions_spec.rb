# frozen_string_literal: true

# Root fields resolve to graphql-ruby Resolver / Mutation classes in their own
# namespaces; builders live apart from them, in theirs.
module Queries
  class Greeting < GraphQL::Schema::Resolver
    def resolve(name:, shout: false)
      text = "Hello, #{name} (from #{context[:origin]})"
      shout ? text.upcase : text
    end

    def authorized?(name:, **)
      raise GraphQL::ExecutionError, 'Strangers are not greeted.' if name == 'stranger'

      true
    end
  end

  class GuardedGreeting < GraphQL::Schema::Resolver
    def resolve(name:) = "Hi #{name}"
  end

  class Explicit < GraphQL::Schema::Resolver
    def resolve = 'explicit'
  end

  class NotAResolver
    def self.call(*) = 'never'
  end
end

module Mutations
  class PublishPost < GraphQL::Schema::Mutation
    def resolve(id:, title:)
      Post.find(id).tap { |post| post.update!(title: title, published: true) }
    end
  end

  # graphql-ruby's install generates Relay-style mutations taking `input:`.
  class RenamePost < GraphQL::Schema::RelayClassicMutation
    def resolve(id:, title:)
      Post.find(id).tap { |post| post.update!(title: title) }
    end
  end

  class CreateDraft < GraphQL::Schema::Mutation
    def resolve(title:, author_id:)
      Post.create!(title: title, author_id: author_id)
    end
  end
end

module Builders
  class Published
    def self.call(relation, _args, _ctx) = relation.where(published: true)
  end
end

module Custom
  class Greeting < GraphQL::Schema::Resolver
    def resolve(**) = 'custom namespace'
  end
end

RSpec.describe 'Query and Mutation resolver classes' do
  let(:sdl) do
    <<~GRAPHQL
      type Query {
        greeting(name: String!, shout: Boolean): String
        guardedGreeting(name: String!): String @guard @cache
        explicitly: String @field(resolver: "Explicit")
        missing: String
        notAResolver: String
        posts: [Post!]! @paginate @builder(class: "Published")
      }

      type Mutation {
        publishPost(id: ID!, title: String!): Post
        renamePost(input: RenamePostInput!): Post
        createDraft(input: CreateDraftInput! @spread): Post @inject(context: "current_user.id", name: "author_id")
      }

      input RenamePostInput { id: ID! title: String! }
      input CreateDraftInput { title: String! }

      type Post {
        id: ID!
        title: String
        published: Boolean
        authorId: ID
      }
    GRAPHQL
  end

  let(:schema) { build_schema(sdl) }

  def run(query, context = {})
    schema.execute(query, context: context).to_h
  end

  describe 'Query fields' do
    it 'resolve to Queries::<FieldName> by convention, with graphql-ruby keyword arguments and context' do
      result = run('{ greeting(name: "Ada", shout: true) }', origin: 'spec')

      expect(result).to eq('data' => { 'greeting' => 'HELLO, ADA (FROM SPEC)' })
    end

    it 'still resolve by convention under wrapping directives, which run first' do
      expect(run('{ guardedGreeting(name: "Ada") }')['errors'].map { |e| e['message'] }).to eq(['Unauthenticated.'])
      expect(run('{ guardedGreeting(name: "Ada") }', current_user: :someone))
        .to eq('data' => { 'guardedGreeting' => 'Hi Ada' })
    end

    it "run the resolver's authorized? hook" do
      result = run('{ greeting(name: "stranger") }')

      expect(result['errors'].map { |e| e['message'] }).to eq(['Strangers are not greeted.'])
    end

    it 'resolve @field(resolver:) in the queries namespace' do
      expect(run('{ explicitly }')).to eq('data' => { 'explicitly' => 'explicit' })
    end

    it 'report a field with no resolver class through on_error' do
      errors = []
      Lighthouse.configure { |c| c.on_error = ->(error, _ctx) { errors << error } }

      expect(run('{ missing }')).to eq('data' => { 'missing' => nil })
      expect(errors.map(&:message)).to eq(['Query.missing has no resolver: define Queries::Missing, or add a resolving directive.'])
    end

    it 'require the conventional class to be a GraphQL::Schema::Resolver' do
      expect { run('{ notAResolver }') }.to raise_error(Lighthouse::DefinitionError, /must inherit from GraphQL::Schema::Resolver/)
    end

    it 'never fall back to a model with the field name' do
      errors = []
      Lighthouse.configure { |c| c.on_error = ->(error, _ctx) { errors << error } }
      sdl = "type Query { post: String }\ntype Post { id: ID }"

      expect(build_schema(sdl).execute('{ post }').to_h).to eq('data' => { 'post' => nil })
      expect(errors.size).to eq(1)
    end

    it 'use Config.namespaces[:queries]' do
      Lighthouse.configure { |c| c.namespaces = { queries: ['Custom'] } }

      expect(run('{ greeting(name: "x") }')).to eq('data' => { 'greeting' => 'custom namespace' })
      expect(Lighthouse::Config.namespaces[:mutations]).to eq(['Mutations'])
    end
  end

  describe 'Mutation fields' do
    let!(:post) { Post.create!(title: 'Draft') }

    it 'resolve to Mutations::<FieldName> (a GraphQL::Schema::Mutation)' do
      result = run(%(mutation { publishPost(id: #{post.id}, title: "Live") { title published } }))

      expect(result).to eq('data' => { 'publishPost' => { 'title' => 'Live', 'published' => true } })
    end

    it "work with graphql-ruby's RelayClassicMutation and its input argument" do
      result = run(%(mutation { renamePost(input: { id: #{post.id}, title: "Renamed" }) { title } }))

      expect(result).to eq('data' => { 'renamePost' => { 'title' => 'Renamed' } })
    end

    it 'receive @spread input fields and @inject context values as keywords' do
      result = run('mutation { createDraft(input: { title: "Mine" }) { title authorId } }', current_user: Struct.new(:id).new(7))

      expect(result).to eq('data' => { 'createDraft' => { 'title' => 'Mine', 'authorId' => '7' } })
    end
  end

  describe 'builders' do
    it 'resolve @builder(class:) in the builders namespace' do
      Post.create!(title: 'Hidden')
      Post.create!(title: 'Shown', published: true)

      expect(run(%({ posts(first: 10) { data { title } } }))).to eq('data' => { 'posts' => { 'data' => [{ 'title' => 'Shown' }] } })
    end
  end
end
