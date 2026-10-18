# frozen_string_literal: true

# @builder on arguments, @limit(builder:), @hasManyThrough / @hasOneThrough and ResolveInfo#lookahead.
class Builders::ArgumentSpecTitled
  def self.call(relation, value, _context) = value.nil? ? relation.where(title: nil) : relation.where(title: value)

  def self.longer_than(relation, value, _context) = relation.where('LENGTH(title) > ?', value)
end

class Builders::ArgumentSpecLimited
  def self.call(relation, value, _context) = relation.limit(value)
end

class LookaheadSpecPosts < GraphQL::Schema::Resolver
  def resolve(**)
    selects = resolve_info.lookahead.selects?(:title) ? 'title' : 'no title'
    [{ title: selects }]
  end
end

class Types::LookaheadPostType < GraphQL::Schema::Object
  include Lighthouse::GraphQL::Type

  def note = "selected: #{resolve_info.lookahead.selections.map(&:name).sort.join(',')}"
end

RSpec.describe '@builder on arguments, @limit and lookahead' do
  describe '@builder on an argument' do
    let(:schema) do
      build_schema(<<~GRAPHQL)
        type Query {
          posts(
            titled: String @builder(class: "ArgumentSpecTitled")
            longerThan: Int @builder(method: "ArgumentSpecTitled@longer_than")
          ): [Post!]! @all
          firstPosts: [Post!]! @all @builder(class: "ArgumentSpecLimited", value: 1)
        }
        type Post { title: String }
      GRAPHQL
    end

    before do
      Post.create!(title: 'Hello')
      Post.create!(title: 'Hi')
    end

    def titles(query) = schema.execute(query).to_h.dig('data', 'posts').pluck('title')

    it "calls the method with the argument's value when the client sends it" do
      expect(titles('{ posts(titled: "Hi") { title } }')).to eq(['Hi'])
      expect(titles('{ posts(longerThan: 2) { title } }')).to eq(['Hello'])
    end

    it 'calls it for an explicit null too, and not when the argument is left out' do
      expect(titles('{ posts(titled: null) { title } }')).to eq([])
      expect(titles('{ posts { title } }')).to eq(%w[Hello Hi])
    end

    it "passes a field's value: instead of the arguments" do
      expect(schema.execute('{ firstPosts { title } }').to_h.dig('data', 'firstPosts')).to eq([{ 'title' => 'Hello' }])
    end
  end

  describe '@limit' do
    let(:sdl) do
      <<~GRAPHQL
        type Query {
          posts(limit: Int @limit(builder: true)): [Post!]! @all @limit
        }
        type Post { title: String }
      GRAPHQL
    end

    it 'puts a LIMIT on the query with builder: true, and is accepted on the field' do
      3.times { |i| Post.create!(title: "p#{i}") }
      sql = []
      callback = ->(*, payload) { sql << payload[:sql] }
      result = ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') { build_schema(sdl).execute('{ posts(limit: 2) { title } }').to_h }

      expect(result.dig('data', 'posts').size).to eq(2)
      expect(sql.grep(/FROM "posts"/).first).to include('LIMIT')
    end

    it 'must be on an Int argument' do
      expect { build_schema('type Query { posts(limit: String @limit): [Post!]! @all } type Post { title: String }') }
        .to raise_error(Lighthouse::DefinitionError, /only be used on arguments of type Int, got posts.limit of type String/)
    end
  end

  describe '@hasManyThrough and @hasOneThrough' do
    include_context 'with PHP Lighthouse models'

    before { LH::Post.has_one :task_owner, through: :task, source: :user unless LH::Post.reflect_on_association(:task_owner) }

    let(:sdl) do
      <<~GRAPHQL
        type Query { users: [User!]! @all(model: "LH::User") posts: [Post!]! @all(model: "LH::Post") }
        type User { name: String roles: [Role!]! @hasManyThrough paged: [Role!]! @hasManyThrough(relation: "roles", type: PAGINATOR) }
        type Role { name: String }
        type Post { title: String taskOwner: User @hasOneThrough }
      GRAPHQL
    end

    it 'resolve has_many / has_one :through, paginated too' do
      ada = LH::User.create!(name: 'ada')
      ada.roles << LH::Role.create!(name: 'admin')
      LH::Post.create!(title: 'p', task: LH::Task.create!(name: 't', user: ada))

      result = schema.execute('{ users { roles { name } paged(first: 5) { data { name } } } posts { taskOwner { name } } }').to_h

      expect(result['data']).to eq('users' => [{ 'roles' => [{ 'name' => 'admin' }], 'paged' => { 'data' => [{ 'name' => 'admin' }] } }],
                                   'posts' => [{ 'taskOwner' => { 'name' => 'ada' } }])
    end
  end

  describe 'ResolveInfo#lookahead' do
    let(:schema) do
      build_schema(<<~GRAPHQL)
        type Query {
          posts(term: String): [Post!]! @field(resolver: "LookaheadSpecPosts") @cache
          first: LookaheadPost @first(model: "Post")
        }
        type Post { title: String }
        type LookaheadPost { title: String note: String }
      GRAPHQL
    end

    it 'tells a resolver class what the client selects below the field' do
      expect(schema.execute('{ posts { title } }').to_h.dig('data', 'posts')).to eq([{ 'title' => 'title' }])
      expect(schema.execute('{ posts(term: "x") { __typename } }').to_h.dig('data', 'posts')).to eq([{ '__typename' => 'Post' }])
    end

    it "tells a type class's method" do
      Post.create!(title: 'Hello')

      expect(schema.execute('{ first { note } }').to_h.dig('data', 'first', 'note')).to eq('selected: ')
    end

    it 'never reaches the arguments, so @cache keys on what the client sent' do
      calls = 0
      allow(LookaheadSpecPosts).to receive(:new).and_wrap_original do |original, **kwargs|
        calls += 1
        original.call(**kwargs)
      end

      2.times { schema.execute('{ posts(term: "same") { title } }') }

      expect(calls).to eq(1)
    end
  end
end
