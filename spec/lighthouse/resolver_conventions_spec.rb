# frozen_string_literal: true

# Root fields resolve to graphql-ruby Resolver / Mutation classes in their own
# namespaces; builders live apart from them, in theirs.
module Resolvers
  # graphql-ruby's convention: every resolver inherits from the namespace's base.
  class BaseResolver < GraphQL::Schema::Resolver
  end

  class Greeting < BaseResolver
    def resolve(name:, shout: false)
      text = "Hello, #{name} (from #{context[:origin]})"
      shout ? text.upcase : text
    end

    def authorized?(name:, **)
      raise GraphQL::ExecutionError, 'Strangers are not greeted.' if name == 'stranger'

      true
    end
  end

  class GuardedGreeting < BaseResolver
    def resolve(name:) = "Hi #{name}"
  end

  class Explicit < BaseResolver
    def resolve = 'explicit'
  end

  module Nested; end

  class Nested::Explicit < BaseResolver
    def resolve = 'nested'
  end

  # A field of another type: `object` is the parent post.
  module Posts; end

  class Posts::Shout < BaseResolver
    def resolve(suffix: '!') = "#{object.title.upcase}#{suffix}"
  end

  class NotAResolver
    def self.call(*) = 'never'
  end
end

module Mutations
  class BaseMutation < GraphQL::Schema::Mutation
  end

  class PublishPost < BaseMutation
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

  class CreateDraft < BaseMutation
    def resolve(title:, author_id:)
      Post.create!(title: title, author_id: author_id)
    end
  end
end

class Builders::Published
  def self.call(relation, _args, _ctx) = relation.where(published: true)
end

class Custom::Greeting < GraphQL::Schema::Resolver
  def resolve(**) = 'custom namespace'
end

# Outside the resolvers namespace: found through resolver_namespaces' fallback.
class ResolverConventionsSpecWhisper
  def self.call(post, _args, _ctx) = post.title.downcase
end

RSpec.describe 'Query and Mutation resolver classes' do
  let(:sdl) do
    <<~GRAPHQL
      type Query {
        greeting(name: String!, shout: Boolean): String
        guardedGreeting(name: String!): String @guard @cache
        explicitly: String @field(resolver: "Explicit")
        nested: String @field(resolver: "Nested::Explicit")
        qualified: String @field(resolver: "Resolvers::Nested::Explicit")
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
        shout(suffix: String): String @field(resolver: "Posts::Shout")
        qualifiedShout: String @field(resolver: "Resolvers::Posts::Shout")
        whisper: String @field(resolver: "ResolverConventionsSpecWhisper")
      }
    GRAPHQL
  end

  let(:schema) { build_schema(sdl) }

  def run(query, context = {})
    schema.execute(query, context: context).to_h
  end

  describe 'Query fields' do
    it 'resolve to Resolvers::<FieldName> by convention, with graphql-ruby keyword arguments and context' do
      result = run('{ greeting(name: "Ada", shout: true) }', origin: 'spec')

      expect(result).to eq('data' => { 'greeting' => 'HELLO, ADA (FROM SPEC)' })
    end

    it 'still resolve by convention under wrapping directives, which run first' do
      expect(run('{ guardedGreeting(name: "Ada") }')['errors'].pluck('message')).to eq(['Unauthenticated.'])
      expect(run('{ guardedGreeting(name: "Ada") }', current_user: :someone))
        .to eq('data' => { 'guardedGreeting' => 'Hi Ada' })
    end

    it "run the resolver's authorized? hook" do
      result = run('{ greeting(name: "stranger") }')

      expect(result['errors'].pluck('message')).to eq(['Strangers are not greeted.'])
    end

    it 'resolve @field(resolver:) in the Query resolvers namespace' do
      expect(run('{ explicitly }')).to eq('data' => { 'explicitly' => 'explicit' })
    end

    it 'resolve a nested @field(resolver:) name in that namespace too, or as written' do
      expect(run('{ nested qualified }')).to eq('data' => { 'nested' => 'nested', 'qualified' => 'nested' })
    end

    it 'report a field with no resolver class through on_error' do
      errors = []
      Lighthouse.configure { |c| c.on_error = ->(error, _ctx) { errors << error } }

      expect(run('{ missing }')).to eq('data' => { 'missing' => nil })
      expect(errors.map(&:message)).to eq(['Query.missing has no resolver: define Resolvers::Missing, or add a resolving directive.'])
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

  describe 'fields of other types' do
    it 'resolve @field(resolver:) in the resolvers namespace, with the parent as object' do
      Post.create!(title: 'Shown', published: true)

      result = run('{ posts(first: 1) { data { shout loud: shout(suffix: "?!") qualifiedShout whisper } } }')

      expect(result.dig('data', 'posts', 'data'))
        .to eq([{ 'shout' => 'SHOWN!', 'loud' => 'SHOWN?!', 'qualifiedShout' => 'SHOWN!', 'whisper' => 'shown' }])
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
