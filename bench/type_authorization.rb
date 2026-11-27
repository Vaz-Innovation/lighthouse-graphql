# frozen_string_literal: true

# What type-level authorization (a type class's scope_items / authorized?,
# docs/authorization.md) costs, on PostgreSQL: each query below, with the post
# type plain, scoped (scope_items), authorized (authorized?) or both. It prints
# the median and p95 time of each, the SQL statements it ran and the posts it
# answered. Numbers in docs/performance.md#type-level-authorization.
#
# Run it with the example app's bundle, which has the pg driver and uses this
# checkout's Lighthouse:
#
#   cd examples/graphql
#   DATABASE_URL=postgres://postgres:postgres@127.0.0.1:5432/lighthouse_bench bundle exec ruby ../../bench/type_authorization.rb
#
# The database is created when missing; its bench_ tables are rebuilt. RUNS=n
# sets the timed runs of each query (default 15); USERS, POSTS_PER_USER and
# COMMENTS_PER_POST the data; VARIANTS (e.g. "Plain ScopedAll") and QUERIES
# (parts of their labels, comma-separated) narrow what runs. To compare with another
# checkout, put its lib first: `bundle exec ruby -I ../other/lib ../../bench/type_authorization.rb`.
require 'active_record'
require 'graphql'
require 'lighthouse-graphql'

USERS = Integer(ENV.fetch('USERS', 200))
POSTS_PER_USER = Integer(ENV.fetch('POSTS_PER_USER', 20))
COMMENTS_PER_POST = Integer(ENV.fetch('COMMENTS_PER_POST', 3))
RUNS = Integer(ENV.fetch('RUNS', 15))
url = ENV.fetch('DATABASE_URL', 'postgres://postgres:postgres@127.0.0.1:5432/lighthouse_bench')

begin
  ActiveRecord::Base.establish_connection(url)
  ActiveRecord::Base.connection.execute('SELECT 1')
rescue ActiveRecord::NoDatabaseError
  ActiveRecord::Base.establish_connection(url.sub(%r{/[^/]+\z}, '/postgres'))
  ActiveRecord::Base.connection.create_database(url[%r{/([^/?]+)\z}, 1])
  ActiveRecord::Base.establish_connection(url)
end
ActiveRecord::Schema.verbose = false
ActiveRecord::Schema.define do
  create_table :bench_users, force: true do |t|
    t.string :name
  end
  create_table :bench_posts, force: true do |t|
    t.string :title
    t.boolean :published, null: false
    t.references :author, null: false
  end
  create_table :bench_comments, force: true do |t|
    t.string :body
    t.references :post, null: false
  end
end

class BenchUser < ActiveRecord::Base
  has_many :posts, class_name: 'BenchPost', foreign_key: :author_id, inverse_of: false
end

class BenchPost < ActiveRecord::Base
  belongs_to :author, class_name: 'BenchUser'
  has_many :comments, class_name: 'BenchComment', foreign_key: :post_id, inverse_of: false
end

class BenchComment < ActiveRecord::Base
  belongs_to :post, class_name: 'BenchPost'
end

# Half the posts are drafts; a user sees the published ones and their own.
BenchUser.insert_all!(Array.new(USERS) { |i| { name: "user #{i}" } })
BenchPost.insert_all!(Array.new(USERS * POSTS_PER_USER) { |i| { title: "post #{i}", published: i.even?, author_id: (i % USERS) + 1 } })
BenchComment.insert_all!(Array.new(USERS * POSTS_PER_USER * COMMENTS_PER_POST) do |i|
  { body: "comment #{i}", post_id: (i % (USERS * POSTS_PER_USER)) + 1 }
end)
ActiveRecord::Base.connection.execute('ANALYZE')

module Types; end

VISIBLE = ->(posts, context) { posts.where(published: true).or(posts.where(author_id: context[:user_id])) }

class Types::PostScopedType < GraphQL::Schema::Object
  include Lighthouse::GraphQL::Type

  def self.scope_items(posts, context) = VISIBLE.call(posts, context)
end

class Types::PostAuthorizedType < GraphQL::Schema::Object
  include Lighthouse::GraphQL::Type

  def self.authorized?(post, context) = super && (post.published || post.author_id == context[:user_id])
end

# The same hooks, keeping every post: what the mechanism costs, the filtering aside.
class Types::PostScopedAllType < GraphQL::Schema::Object
  include Lighthouse::GraphQL::Type

  def self.scope_items(posts, _context) = posts.where(published: [true, false])
end

class Types::PostAuthorizedAllType < GraphQL::Schema::Object
  include Lighthouse::GraphQL::Type

  def self.authorized?(post, context) = super && post.author_id.positive?
end

class Types::PostBothType < GraphQL::Schema::Object
  include Lighthouse::GraphQL::Type

  def self.scope_items(posts, context) = VISIBLE.call(posts, context)
  def self.authorized?(post, context) = super && (post.published || post.author_id == context[:user_id])
end

def schema_for(variant)
  post = "Post#{variant}"
  Lighthouse::GraphQL::SchemaFactory.build_base_schema(sdl: <<~GRAPHQL, schema_options: { using: { GraphQL::Dataloader => {} } })
    type Query {
      pagedPosts: [#{post}!]! @paginate(model: "BenchPost")
      users: [User#{variant}!]! @all(model: "BenchUser")
      comments: [Comment#{variant}!]! @paginate(model: "BenchComment", maxCount: 1000)
      post(id: ID! @eq): #{post} @find(model: "BenchPost")
    }
    type User#{variant} @model(class: "BenchUser") {
      name: String
      posts: [#{post}]! @hasMany
      postsCount: Int! @withCount(relation: "posts")
    }
    type #{post} @model(class: "BenchPost") {
      title: String
      published: Boolean!
      authorId: ID!
      author: User#{variant}! @belongsTo
      comments: [Comment#{variant}!]! @hasMany
    }
    type Comment#{variant} @model(class: "BenchComment") {
      body: String
      post: #{post} @belongsTo
    }
  GRAPHQL
end

QUERIES = {
  'page of 100 posts, with total' => '{ pagedPosts(first: 100) { paginatorInfo { total } data { title author { name } } } }',
  'users → posts → comments' => '{ users { name posts { title comments { body } } } }',
  '1000 comments → post' => '{ comments(first: 1000) { data { body post { title } } } }',
  'users with posts counted' => '{ users { name postsCount } }',
  'a draft by id' => '{ post(id: "2") { title } }'
}.freeze

# The posts an answer holds.
def posts_in(data)
  case data
  when Hash then (data['title'].to_s.start_with?('post ') ? 1 : 0) + data.values.sum { |value| posts_in(value) }
  when Array then data.sum { |value| posts_in(value) }
  else 0
  end
end

def measure(schema, query)
  context = { user_id: 1 }
  3.times { schema.execute(query, context: context) }
  statements = 0
  count = ->(*, payload) { statements += 1 unless payload[:name] == 'SCHEMA' }
  result = nil
  ActiveSupport::Notifications.subscribed(count, 'sql.active_record') { result = schema.execute(query, context: context) }
  times = Array.new(RUNS) do
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    schema.execute(query, context: context)
    (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000
  end.sort
  { median: times[times.size / 2], p95: times[(times.size * 0.95).ceil - 1], statements: statements,
    posts: posts_in(result['data']), errors: result['errors']&.size || 0 }
end

postgres = ActiveRecord::Base.connection.select_value('SHOW server_version')[/\A[\d.]+/]
puts "#{USERS} users, #{USERS * POSTS_PER_USER} posts (half drafts), #{USERS * POSTS_PER_USER * COMMENTS_PER_POST} comments; " \
     "#{RUNS} runs each; ruby #{RUBY_VERSION}, graphql #{GraphQL::VERSION}, PostgreSQL #{postgres}"
variants = ENV.fetch('VARIANTS', 'Plain ScopedAll AuthorizedAll Scoped Authorized Both').split
schemas = variants.index_with { |variant| schema_for(variant) }
only = ENV['QUERIES']&.split(',')
QUERIES.each do |label, query|
  next if only&.none? { |part| label.include?(part) }

  puts "\n#{label}"
  puts '  post type       median ms     p95 ms    SQL  posts errors'
  variants.each do |variant|
    m = measure(schemas[variant], query)
    puts format('  %-14s %10.1f %10.1f %6d %6d %6d', variant, m[:median], m[:p95], m[:statements], m[:posts], m[:errors])
  end
end
