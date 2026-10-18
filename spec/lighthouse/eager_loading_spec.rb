# frozen_string_literal: true

# @with, @withCount and @lazyLoad: eager loading for fields the relation
# directives do not resolve themselves.
class Types::EagerUserType < GraphQL::Schema::Object
  include Lighthouse::GraphQL::Type

  def task_names = object.tasks.map(&:name).sort.join(',')

  def comment_total = object.posts.sum { |post| post.comments.size }

  def activity = "#{object.posts_count} posts"
end

RSpec.describe 'Eager loading directives' do
  include_context 'with PHP Lighthouse models'

  let(:sdl) do
    <<~GRAPHQL
      type Query {
        users: [EagerUser!]! @all(model: "LH::User")
        pagedUsers: [EagerUser!]! @paginate(model: "LH::User") @lazyLoad(relations: ["tasks"])
        companies: [EagerCompany!]! @all(model: "LH::Company")
      }

      type EagerUser {
        name: String
        taskNames: String @with(relation: "tasks")
        commentTotal: Int @with(relation: "posts.comments")
        activity: String @withCount(relation: "posts")
        postsCount: Int @withCount(relation: "posts")
        posts: [EagerPost!]! @hasMany @lazyLoad(relations: ["comments"])
        tasksLoaded: Boolean @method(name: "tasks_loaded?")
      }

      type EagerPost { title: String commentCount: Int @method(name: "comment_count") }

      type EagerCompany {
        namedUsers: Int @withCount(relation: "users", scopes: ["named"]) @rename(attribute: "users_count")
      }
    GRAPHQL
  end

  before do
    LH::User.define_method(:tasks_loaded?) { association(:tasks).loaded? }
    LH::Post.define_method(:comment_count) { comments.size }
  end

  after do
    LH::User.remove_method(:tasks_loaded?)
    LH::Post.remove_method(:comment_count)
  end

  def run(query) = build_schema(sdl, dataloader: true).execute(query).to_h

  def queries(&block)
    sql = []
    callback = ->(*, payload) { sql << payload[:sql] unless payload[:name] == 'SCHEMA' }
    ActiveSupport::Notifications.subscribed(callback, 'sql.active_record', &block)
    sql
  end

  def create_users(count)
    Array.new(count) do |i|
      user = LH::User.create!(name: "u#{i}")
      2.times { |t| LH::Task.create!(name: "t#{user.id}-#{t}", user: user) }
      post = LH::Post.create!(title: "p#{i}", user: user)
      2.times { LH::Comment.create!(comment: 'c', post: post) }
      user
    end
  end

  describe '@with' do
    it 'loads the relation for every parent before the field resolves' do
      users = create_users(2)

      expect(run('{ users { taskNames } }').dig('data', 'users').pluck('taskNames')).to eq(users.map { |u| "t#{u.id}-0,t#{u.id}-1" })
    end

    it 'runs the same number of queries for any number of parents, nested relations too' do
      create_users(2)
      few = queries { run('{ users { taskNames commentTotal } }') }.size
      create_users(4)

      expect(queries { run('{ users { taskNames commentTotal } }') }.size).to eq(few)
      expect(run('{ users { commentTotal } }').dig('data', 'users').pluck('commentTotal')).to all(eq(2))
    end
  end

  describe '@withCount' do
    it 'keeps the count on the parent as <relation>_count, for a method or the default reader to read' do
      create_users(2)

      expect(run('{ users { activity postsCount } }').dig('data', 'users')).to eq([{ 'activity' => '1 posts', 'postsCount' => 1 }] * 2)
    end

    it 'counts every parent in one query, through the scopes given' do
      company = LH::Company.create!(name: 'c')
      LH::User.create!(company: company, name: 'named')
      LH::User.create!(company: company, name: nil)
      count_queries = queries { run('{ companies { namedUsers } }') }.grep(/COUNT/i)

      expect(run('{ companies { namedUsers } }').dig('data', 'companies')).to eq([{ 'namedUsers' => 1 }])
      expect(count_queries.size).to eq(1)
    end

    it 'marshals a record that carries counts, for @cache' do
      create_users(1)
      user = LH::User.first
      Lighthouse::GraphQL::RelationCounts.write(user, 'posts', 3)

      expect(Marshal.load(Marshal.dump(user)).posts_count).to eq(3)
    end
  end

  describe '@lazyLoad' do
    it "loads the relations of a relation directive's records, for all its parents at once" do
      create_users(2)
      few = queries { run('{ users { posts { commentCount } } }') }.size
      create_users(4)

      expect(queries { run('{ users { posts { commentCount } } }') }.size).to eq(few)
      expect(run('{ users { posts { commentCount } } }').dig('data', 'users').flat_map { |u| u['posts'] }.pluck('commentCount')).to all(eq(2))
    end

    it "loads them into a @paginate page's records" do
      create_users(2)

      expect(run('{ pagedUsers(first: 5) { data { tasksLoaded } } }').dig('data', 'pagedUsers', 'data')).to eq([{ 'tasksLoaded' => true }] * 2)
    end
  end
end
