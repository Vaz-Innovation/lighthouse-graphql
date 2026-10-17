# frozen_string_literal: true

require 'active_support/testing/time_helpers'

# Counts its calls, so a test can tell a cache hit from a resolver run.
class CacheSpecCounter
  class << self
    attr_accessor :calls

    def call(obj, args, _ctx)
      self.calls += 1
      "#{obj&.respond_to?(:title) ? obj.title : 'root'}:#{args[:n]}:#{calls}"
    end
  end
end

class CacheSpecRename
  def self.call(_obj, args, _ctx)
    Post.where(id: args[:ids]).each { |post| post.update!(title: args[:title]) }.to_a
  end
end

RSpec.describe '@cache, @cacheKey and @clearCache' do
  include ActiveSupport::Testing::TimeHelpers

  let(:sdl) do
    <<~GRAPHQL
      type Query {
        counter(n: Int): String @field(resolver: "CacheSpecCounter") @cache
        expiring: String @field(resolver: "CacheSpecCounter") @cache(maxAge: 60)
        mine: String @field(resolver: "CacheSpecCounter") @cache(private: true)
        post(id: ID! @eq): Post @find
        profile: Profile @field(resolver: "CacheSpecProfile")
        guarded(id: ID! @eq): Post @find @cache @canResolved(ability: "show")
        unserializable: String @field(resolver: "CacheSpecUnserializable") @cache
      }

      type Mutation {
        touchPosts: Boolean @field(resolver: "CacheSpecTrue") @clearCache(type: "Post")
        touchPost(id: ID!): Boolean @field(resolver: "CacheSpecTrue") @clearCache(type: "Post", idSource: { argument: "id" })
        touchSummary(id: ID!): Boolean
          @field(resolver: "CacheSpecTrue") @clearCache(type: "Post", idSource: { argument: "id" }, field: "summary")
        renamePosts(ids: [ID!]!, title: String!): [Post!]!
          @field(resolver: "CacheSpecRename") @clearCache(type: "Post", idSource: { field: "*.id" })
        touchCounter: Boolean @field(resolver: "CacheSpecTrue") @clearCache(type: "Query", field: "counter")
      }

      type Post {
        id: ID!
        title: String
        summary: String @field(resolver: "CacheSpecCounter") @cache
        teaser: String @field(resolver: "CacheSpecCounter") @cache
      }

      type Profile {
        username: String @cacheKey
        bio: String @field(resolver: "CacheSpecCounter") @cache
      }
    GRAPHQL
  end

  let(:schema) { build_schema(sdl, dataloader: true) }
  let!(:first) { Post.create!(title: 'First', published: true) }
  let!(:second) { Post.create!(title: 'Second') }

  before do
    CacheSpecCounter.calls = 0
    stub_const('CacheSpecTrue', Class.new { def self.call(*) = true })
    stub_const('CacheSpecProfile', Class.new { def self.call(_o, _a, ctx) = { 'username' => ctx[:username] } })
    stub_const('CacheSpecUnserializable', Class.new { def self.call(*) = Class.new })
    stub_const('PostPolicy', Class.new do
      def initialize(user, record) = (@user, @record = user, record)
      def show? = @user == :admin || @record.published
    end)
    Lighthouse.configure do |c|
      c.authenticated_user = ->(ctx) { ctx[:current_user] }
      c.policy_user = ->(ctx) { ctx[:current_user] }
      c.on_error = ->(error, _ctx) { (@errors ||= []) << error }
    end
  end

  def run(query, context = {})
    schema.execute(query, context: context).to_h
  end

  def value(query, context = {})
    result = run(query, context)
    raise result['errors'].inspect if result['errors']

    result['data'].values.first
  end

  describe '@cache' do
    it 'resolves once and serves the stored value afterwards' do
      expect(value('{ counter }')).to eq('root::1')
      expect(value('{ counter }')).to eq('root::1')
      expect(CacheSpecCounter.calls).to eq(1)
    end

    it 'keys entries by arguments' do
      expect(value('{ counter(n: 1) }')).to eq('root:1:1')
      expect(value('{ counter(n: 2) }')).to eq('root:2:2')
      expect(value('{ counter(n: 1) }')).to eq('root:1:1')
    end

    it 'expires entries after maxAge seconds' do
      expect(value('{ expiring }')).to eq('root::1')
      travel(59.seconds) { expect(value('{ expiring }')).to eq('root::1') }
      travel(61.seconds) { expect(value('{ expiring }')).to eq('root::2') }
    end

    it 'keeps one entry per user with private: true, which guests share' do
      expect(value('{ mine }', current_user: Struct.new(:id).new(1))).to eq('root::1')
      expect(value('{ mine }', current_user: Struct.new(:id).new(2))).to eq('root::2')
      expect(value('{ mine }', current_user: Struct.new(:id).new(1))).to eq('root::1')
      expect(value('{ mine }')).to eq('root::3')
      expect(value('{ mine }')).to eq('root::3')
    end

    it "keys a field by its parent's ID field" do
      expect(value("{ post(id: #{first.id}) { summary } }")).to eq('summary' => 'First::1')
      expect(value("{ post(id: #{second.id}) { summary } }")).to eq('summary' => 'Second::2')
      expect(value("{ post(id: #{first.id}) { summary } }")).to eq('summary' => 'First::1')
    end

    it 'keys a field by the parent field marked @cacheKey' do
      expect(value('{ profile { bio } }', username: 'ada')).to eq('bio' => 'root::1')
      expect(value('{ profile { bio } }', username: 'alan')).to eq('bio' => 'root::2')
      expect(value('{ profile { bio } }', username: 'ada')).to eq('bio' => 'root::1')
    end

    it 'still authorizes a cached value' do
      expect(value("{ guarded(id: #{second.id}) { title } }", current_user: :admin)).to eq('title' => 'Second')

      result = run("{ guarded(id: #{second.id}) { title } }", current_user: :reader)
      expect(result['errors'].map { |e| e['message'] }).to eq(['This action is unauthorized.'])
    end

    it 'reports a value the store cannot serialize, and returns it uncached' do
      result = run('{ unserializable }')

      expect(result['data']).to have_key('unserializable')
      expect(@errors.map(&:class)).to eq([TypeError])
    end
  end

  describe '@clearCache' do
    def summaries
      [value("{ post(id: #{first.id}) { summary } }")['summary'], value("{ post(id: #{second.id}) { summary } }")['summary']]
    end

    before { summaries } # cache First::1 and Second::2

    it 'clears every entry of a type' do
      run('mutation { touchPosts }')

      expect(summaries).to eq(%w[First::3 Second::4])
    end

    it 'clears one id taken from an argument' do
      run("mutation { touchPost(id: #{first.id}) }")

      expect(summaries).to eq(%w[First::3 Second::2])
    end

    it 'clears one field of one id' do
      teaser = -> { value("{ post(id: #{first.id}) { teaser } }")['teaser'] }
      expect(teaser.call).to eq('First::3')

      run("mutation { touchSummary(id: #{first.id}) }")

      expect(summaries).to eq(%w[First::4 Second::2])
      expect(teaser.call).to eq('First::3')
    end

    it 'clears the ids found in the result' do
      run(%(mutation { renamePosts(ids: [#{first.id}, #{second.id}], title: "Renamed") { id } }))

      expect(summaries).to eq(%w[Renamed::3 Renamed::4])
    end

    it 'clears a root field' do
      expect(value('{ counter }')).to eq('root::3')
      run('mutation { touchCounter }')

      expect(value('{ counter }')).to eq('root::4')
    end

    it 'does not clear when the mutation fails' do
      failing = build_schema(<<~GRAPHQL)
        type Query { a: String }
        type Mutation { boom: Boolean @field(resolver: "CacheSpecBoom") @clearCache(type: "Post") }
      GRAPHQL
      stub_const('CacheSpecBoom', Class.new { def self.call(*) = raise(GraphQL::ExecutionError, 'boom') })

      failing.execute('mutation { boom }')

      expect(summaries).to eq(%w[First::1 Second::2])
    end
  end
end
