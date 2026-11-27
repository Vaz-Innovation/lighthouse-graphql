# frozen_string_literal: true

# What bounding a mutation's input costs (docs/mutations.md#what-an-input-may-reach):
# each nested operation below, with the task and role types plain or scoped
# (a scope_items that keeps every record, so only the mechanism is measured).
# It prints the median and p95 time of each and the SQL statements it ran
# (SELECT, INSERT, UPDATE, DELETE). Every run is rolled back, so each one
# starts from the same rows. Numbers in docs/performance.md#nested-mutations.
#
# Run it with the example app's bundle, which has the pg driver:
#
#   cd examples/graphql
#   DATABASE_URL=postgres://postgres:postgres@127.0.0.1:5432/lighthouse_bench bundle exec ruby ../../bench/nested_mutations.rb
#
# RUNS=n sets the timed runs (default 30), IDS=n how many records each list
# operation names (default 10). To compare with another checkout, put its lib
# first: `bundle exec ruby -I ../other/lib ../../bench/nested_mutations.rb`.
require 'active_record'
require 'graphql'
require 'lighthouse-graphql'

RUNS = Integer(ENV.fetch('RUNS', 30))
IDS = Integer(ENV.fetch('IDS', 10))
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
  create_table :bench_mutation_users, force: true do |t|
    t.string :name
  end
  create_table :bench_mutation_tasks, force: true do |t|
    t.string :name
    t.references :user
  end
  create_table :bench_mutation_roles, force: true do |t|
    t.string :name
  end
  create_table :bench_mutation_role_users, force: true do |t|
    t.references :user, null: false
    t.references :role, null: false
  end
  create_table :bench_mutation_posts, force: true do |t|
    t.string :title
    t.references :task
  end
end

class BenchMutationUser < ActiveRecord::Base
  has_many :tasks, class_name: 'BenchMutationTask', foreign_key: :user_id, inverse_of: :user
  has_many :role_users, class_name: 'BenchMutationRoleUser', foreign_key: :user_id, inverse_of: :user
  has_many :roles, through: :role_users
end

class BenchMutationTask < ActiveRecord::Base
  belongs_to :user, class_name: 'BenchMutationUser', optional: true
end

class BenchMutationRole < ActiveRecord::Base
end

class BenchMutationRoleUser < ActiveRecord::Base
  belongs_to :user, class_name: 'BenchMutationUser'
  belongs_to :role, class_name: 'BenchMutationRole'
end

class BenchMutationPost < ActiveRecord::Base
  belongs_to :task, class_name: 'BenchMutationTask', optional: true
end

# User 1 has IDS tasks and IDS roles; IDS loose tasks and IDS more roles are related to no one.
BenchMutationUser.insert_all!([{ name: 'user' }])
BenchMutationTask.insert_all!(Array.new(IDS) { |i| { name: "own #{i}", user_id: 1 } } + Array.new(IDS) { |i| { name: "loose #{i}", user_id: nil } })
BenchMutationRole.insert_all!(Array.new(IDS * 2) { |i| { name: "role #{i}" } })
BenchMutationRoleUser.insert_all!(Array.new(IDS) { |i| { user_id: 1, role_id: i + 1 } })
ActiveRecord::Base.connection.execute('ANALYZE')

module Types; end

class Types::TaskScopedType < GraphQL::Schema::Object
  include Lighthouse::GraphQL::Type

  def self.scope_items(tasks, _context) = tasks.where.not(name: nil)
end

class Types::RoleScopedType < GraphQL::Schema::Object
  include Lighthouse::GraphQL::Type

  def self.scope_items(roles, _context) = roles.where.not(name: nil)
end

def schema_for(variant)
  Lighthouse::GraphQL::SchemaFactory.build_base_schema(sdl: <<~GRAPHQL)
    type Query { tasks: [Task#{variant}!]! @all(model: "BenchMutationTask") roles: [Role#{variant}!]! @all(model: "BenchMutationRole") }
    type User @model(class: "BenchMutationUser") { id: ID! name: String }
    type Task#{variant} @model(class: "BenchMutationTask") { id: ID! name: String }
    type Role#{variant} @model(class: "BenchMutationRole") { id: ID! name: String }
    type Post @model(class: "BenchMutationPost") { id: ID! }

    type Mutation {
      updateUser(input: UpdateUserInput! @spread): User @update(model: "BenchMutationUser")
      updateTask(input: UpdateTaskInput! @spread): Task#{variant} @update(model: "BenchMutationTask")
      upsertTask(input: UpsertTaskInput! @spread): Task#{variant} @upsert(model: "BenchMutationTask")
      createPost(input: CreatePostInput! @spread): Post @create(model: "BenchMutationPost")
    }

    input UpdateUserInput { id: ID! tasks: TaskOperations roles: RoleOperations }
    input TaskOperations {
      update: [UpdateTaskInput!]
      upsert: [UpsertTaskInput!]
      delete: [ID!]
      connect: [ID!]
      disconnect: [ID!]
    }
    input UpdateTaskInput { id: ID! name: String }
    input UpsertTaskInput { id: ID name: String }
    input RoleOperations { connect: [ID!] sync: [ID!] delete: [ID!] }
    input CreatePostInput { task: PostTaskOperations }
    input PostTaskOperations { connect: ID }
  GRAPHQL
end

own = (1..IDS).to_a
loose = ((IDS + 1)..(IDS * 2)).to_a
fresh = Array.new(IDS) { |i| 1_000_000 + i }
user = ->(operations) { { 'input' => { 'id' => 1, **operations } } }
UPDATE_USER = 'mutation($input: UpdateUserInput!) { updateUser(input: $input) { id } }'

MUTATIONS = {
  "update #{IDS} tasks" => [UPDATE_USER, user.call('tasks' => { 'update' => own.map { |id| { 'id' => id, 'name' => "renamed #{id}" } } })],
  "upsert #{IDS} tasks by id" => [UPDATE_USER, user.call('tasks' => { 'upsert' => own.map { |id| { 'id' => id, 'name' => "up #{id}" } } })],
  "upsert #{IDS} new tasks with ids" => [UPDATE_USER, user.call('tasks' => { 'upsert' => fresh.map { |id| { 'id' => id, 'name' => "new #{id}" } } })],
  "delete #{IDS} tasks" => [UPDATE_USER, user.call('tasks' => { 'delete' => own })],
  "disconnect #{IDS} tasks" => [UPDATE_USER, user.call('tasks' => { 'disconnect' => own })],
  "connect #{IDS} tasks (has-many)" => [UPDATE_USER, user.call('tasks' => { 'connect' => loose })],
  "connect #{IDS} roles (many-to-many)" => [UPDATE_USER, user.call('roles' => { 'connect' => loose })],
  "sync #{IDS} roles" => [UPDATE_USER, user.call('roles' => { 'sync' => loose })],
  "delete #{IDS} roles" => [UPDATE_USER, user.call('roles' => { 'delete' => own })],
  'connect a task (belongs-to)' => ['mutation($input: CreatePostInput!) { createPost(input: $input) { id } }',
                                    { 'input' => { 'task' => { 'connect' => 1 } } }],
  'update a task (root)' => ['mutation($input: UpdateTaskInput!) { updateTask(input: $input) { id } }',
                             { 'input' => { 'id' => 1, 'name' => 'root' } }],
  'upsert a new task with an id (root)' => ['mutation($input: UpsertTaskInput!) { upsertTask(input: $input) { id } }',
                                            { 'input' => { 'id' => 2_000_000, 'name' => 'root' } }]
}.freeze

WRITES_AND_READS = /\A\s*(SELECT|INSERT|UPDATE|DELETE)/i

# One run, rolled back.
def run(schema, query, variables)
  result = nil
  ActiveRecord::Base.transaction do
    result = schema.execute(query, variables: variables)
    raise ActiveRecord::Rollback
  end
  raise "#{query}: #{result['errors'].inspect}" if result['errors']
end

def measure(schema, query, variables)
  3.times { run(schema, query, variables) }
  statements = 0
  count = ->(*, payload) { statements += 1 if payload[:sql].match?(WRITES_AND_READS) && payload[:name] != 'SCHEMA' }
  ActiveSupport::Notifications.subscribed(count, 'sql.active_record') { run(schema, query, variables) }
  times = Array.new(RUNS) do
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    run(schema, query, variables)
    (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000
  end.sort
  { median: times[times.size / 2], p95: times[(times.size * 0.95).ceil - 1], statements: statements }
end

postgres = ActiveRecord::Base.connection.select_value('SHOW server_version')[/\A[\d.]+/]
puts "#{RUNS} runs each, #{IDS} ids per list; ruby #{RUBY_VERSION}, graphql #{GraphQL::VERSION}, PostgreSQL #{postgres}"
variants = ENV.fetch('VARIANTS', 'Plain Scoped').split
schemas = variants.index_with { |variant| schema_for(variant) }
puts '  mutation                             types    median ms     p95 ms   SQL'
MUTATIONS.each do |label, (query, variables)|
  variants.each do |variant|
    m = measure(schemas[variant], query, variables)
    puts format('  %-36s %-7s %10.2f %10.2f %5d', label, variant, m[:median], m[:p95], m[:statements])
  end
end
