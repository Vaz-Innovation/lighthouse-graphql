# frozen_string_literal: true

ActiveRecord::Schema.define do
  create_table :type_auth_users, force: true do |t|
    t.string :name
  end

  create_table :type_auth_posts, force: true do |t|
    t.string :title
    t.boolean :published, default: false
    t.integer :author_id
  end

  create_table :type_auth_comments, force: true do |t|
    t.string :body
    t.integer :post_id
    t.integer :author_id
  end
end

class TypeAuthUser < ApplicationRecord
  has_many :posts, class_name: 'TypeAuthPost', foreign_key: :author_id, inverse_of: false
  has_many :comments, class_name: 'TypeAuthComment', foreign_key: :author_id, inverse_of: false
end

class TypeAuthPost < ApplicationRecord
end

class TypeAuthComment < ApplicationRecord
  belongs_to :post, class_name: 'TypeAuthPost', optional: true
end

# A post is visible when published, or to its author: once, on the type.
class Types::TaPostType < GraphQL::Schema::Object
  include Lighthouse::GraphQL::Type

  def self.scope_items(posts, context)
    user = context[:current_user]
    posts.where(published: true).or(posts.where(author_id: user&.id))
  end
end

# The same model as another type, with only an object-level rule.
class Types::TaGuardedPostType < GraphQL::Schema::Object
  include Lighthouse::GraphQL::Type

  def self.authorized?(post, context) = super && post.title != 'Secret'
end

# Scopes the search specs' model.
class Types::TaSearchedType < GraphQL::Schema::Object
  include Lighthouse::GraphQL::Type

  def self.scope_items(posts, _context) = posts.where(author_id: nil)
end

# A scope_items that answers no relation.
class Types::TaBrokenType < GraphQL::Schema::Object
  include Lighthouse::GraphQL::Type

  def self.scope_items(items, _context) = items.to_a
end

RSpec.describe "A type class's authorized? and scope_items" do
  let(:sdl) do
    <<~GRAPHQL
      type Query {
        posts: [TaPost!]! @all(model: "TypeAuthPost")
        pagedPosts: [TaPost!]! @paginate(model: "TypeAuthPost")
        post(id: ID! @eq): TaPost @find(model: "TypeAuthPost")
        postCount: Int! @count(model: "TypeAuthPost")
        guarded: [TaGuardedPost]! @all(model: "TypeAuthPost")
        users: [TaUser!]! @all(model: "TypeAuthUser")
      }

      type TaUser @model(class: "TypeAuthUser") {
        name: String
        posts: [TaPost!]! @hasMany
        postsCount: Int! @withCount(relation: "posts")
        comments: [TaComment!]! @hasMany
      }

      type TaComment @model(class: "TypeAuthComment") {
        body: String
        post: TaPost @belongsTo
      }

      type TaPost @model(class: "TypeAuthPost") {
        id: ID!
        title: String
      }

      type TaGuardedPost @model(class: "TypeAuthPost") {
        title: String
      }
    GRAPHQL
  end
  let(:schema) { build_schema(sdl, dataloader: true) }

  let!(:ada) { TypeAuthUser.create!(name: 'Ada') }
  let!(:grace) { TypeAuthUser.create!(name: 'Grace') }
  let!(:live) { TypeAuthPost.create!(title: 'Live', published: true, author_id: ada.id) }
  let!(:draft) { TypeAuthPost.create!(title: 'Draft', published: false, author_id: ada.id) }

  before do
    TypeAuthPost.create!(title: 'Secret', published: true, author_id: ada.id)
    [live, draft].each { |post| TypeAuthComment.create!(body: "On #{post.title}", post_id: post.id, author_id: grace.id) }
  end

  after { [TypeAuthComment, TypeAuthPost, TypeAuthUser].each(&:delete_all) }

  def run(query, user: grace, variables: {})
    result = schema.execute(query, variables: variables, context: { current_user: user })
    expect(result['errors']).to be_nil, -> { result['errors'].inspect }
    result['data']
  end

  def sql_on(table, &block)
    queries = []
    count = ->(*, payload) { queries << payload[:sql] if payload[:sql].include?(table) }
    ActiveSupport::Notifications.subscribed(count, 'sql.active_record', &block)
    queries
  end

  describe 'scope_items' do
    it 'narrows a root list, for the user asking' do
      expect(run('{ posts { title } }')['posts'].pluck('title')).to contain_exactly('Live', 'Secret')
      expect(run('{ posts { title } }', user: ada)['posts'].pluck('title')).to contain_exactly('Live', 'Draft', 'Secret')
    end

    it 'narrows a page in the query, so its total is true' do
      page = run('{ pagedPosts(first: 10) { paginatorInfo { total } data { title } } }')['pagedPosts']

      expect(page['paginatorInfo']['total']).to eq(2)
      expect(page['data'].pluck('title')).to contain_exactly('Live', 'Secret')
    end

    it 'finds nothing the scope leaves out' do
      expect(run('query($id: ID!) { post(id: $id) { title } }', variables: { id: draft.id })['post']).to be_nil
      expect(run('query($id: ID!) { post(id: $id) { title } }', user: ada, variables: { id: draft.id })['post']).to eq('title' => 'Draft')
    end

    it "counts what the scope keeps, through the model's type" do
      expect(run('{ postCount }')['postCount']).to eq(2)
      expect(run('{ postCount }', user: ada)['postCount']).to eq(3)
    end

    it 'follows a relation the root field never sees: comment.post walks back to no draft' do
      comments = run('{ users { name comments { body post { title } } } }')['users'].find { |u| u['name'] == 'Grace' }['comments']

      expect(comments.to_h { |c| [c['body'], c.dig('post', 'title')] }).to eq('On Live' => 'Live', 'On Draft' => nil)
    end

    it 'keeps a relationship batched: one query to load, one to scope, for every parent' do
      queries = sql_on('type_auth_posts') { run('{ users { name posts { title } } }') }
      users = run('{ users { name posts { title } } }')['users'].to_h { |u| [u['name'], u['posts'].map { |p| p['title'] }] }

      expect(users).to eq('Ada' => %w[Live Secret], 'Grace' => [])
      expect(queries.size).to eq(2)
    end

    it 'scopes an entity lookup' do
      subgraph = build_subgraph(<<~GRAPHQL, dataloader: true)
        type Query { posts: [TaPost!]! @all(model: "TypeAuthPost") }
        type TaPost @model(class: "TypeAuthPost") @key(fields: "id") { id: ID! title: String }
      GRAPHQL
      query = 'query($r: [_Any!]!) { _entities(representations: $r) { ... on TaPost { title } } }'
      representations = [{ __typename: 'TaPost', id: live.id.to_s }, { __typename: 'TaPost', id: draft.id.to_s }]

      result = subgraph.execute(query, variables: { r: representations }, context: { current_user: grace })

      expect(result['data']['_entities']).to eq([{ 'title' => 'Live' }, nil])
    end

    it 'counts a relation (@withCount) with the scope too' do
      counts = run('{ users { name postsCount } }')['users'].to_h { |u| [u['name'], u['postsCount']] }

      expect(counts).to eq('Ada' => 2, 'Grace' => 0)
      expect(run('{ users { name postsCount } }', user: ada)['users'].find { |u| u['name'] == 'Ada' }['postsCount']).to eq(3)
    end

    it 'must answer a relation' do
      broken = build_schema(<<~GRAPHQL)
        type Query { broken: [TaBroken!]! @all(model: "TypeAuthPost") }
        type TaBroken @model(class: "TypeAuthPost") { title: String }
      GRAPHQL

      result = broken.execute('{ broken { title } }', context: { current_user: grace })

      expect(result['errors'].pluck('message').join).to include('Types::TaBrokenType.scope_items must answer a relation')
    end

    it "refuses a search outside the database, which can't take the scope" do
      Lighthouse::Config.search = FakeSearch::Engine.new([SearchPost], [])
      searched = build_schema(<<~GRAPHQL)
        type Query { searched(search: String @search): [TaSearched!]! @all(model: "SearchPost") }
        type TaSearched @model(class: "SearchPost") { title: String }
      GRAPHQL

      result = searched.execute('{ searched(search: "great") { title } }', context: { current_user: grace })

      expect(result['errors'].pluck('message').join).to include("cannot apply the scope_items of TaSearched's type class")
    end
  end

  describe 'authorized?' do
    it 'hides each object its class refuses, wherever it is returned' do
      titles = run('{ guarded { title } }')['guarded'].map { |p| p&.dig('title') }

      expect(titles).to contain_exactly('Live', 'Draft', nil)
    end
  end
end
