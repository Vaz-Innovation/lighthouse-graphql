# frozen_string_literal: true

# The models PHP Lighthouse's own test suite runs against (tests/Utils/Models),
# rebuilt in ActiveRecord, so its integration tests can be ported as they are.
# Namespaced and on lh_* tables to stay apart from the other specs' models.
ActiveRecord::Schema.define do
  create_table :lh_companies, force: true do |t|
    t.string :name
  end

  create_table :lh_teams, force: true do |t|
    t.string :name
  end

  create_table :lh_users, force: true do |t|
    t.string :name
    t.string :email
    t.integer :company_id
    t.integer :team_id
  end

  create_table :lh_tasks, force: true do |t|
    t.string :name, index: { unique: true }
    t.integer :user_id
    t.integer :difficulty
  end

  create_table :lh_posts, force: true do |t|
    t.string :title
    t.string :body
    t.integer :task_id
    t.integer :user_id
  end

  create_table :lh_comments, force: true do |t|
    t.string :comment
    t.integer :post_id
  end

  create_table :lh_roles, force: true do |t|
    t.string :name
  end

  create_table :lh_role_user, force: true do |t|
    t.integer :user_id
    t.integer :role_id
    t.string :meta
  end

  create_table :lh_images, force: true do |t|
    t.string :url
    t.integer :imageable_id
    t.string :imageable_type
  end

  create_table :lh_tags, force: true do |t|
    t.string :name
    t.string :default_string, null: false, default: 'this is the default string'
  end

  create_table :lh_categories, id: false, force: true do |t|
    t.primary_key :category_id
    t.string :name
  end

  create_table :lh_taggables, force: true do |t|
    t.integer :tag_id
    t.integer :taggable_id
    t.string :taggable_type
  end

  create_table :lh_custom_primary_keys, id: false, force: true do |t|
    t.primary_key :custom_primary_key_id
    t.integer :user_id
  end
end

module LH
  # PHP Lighthouse's schemas need a Query type; most tests only define mutations.
  PLACEHOLDER_QUERY = "\ntype Query { foo: Int }\n"

  TABLES = %w[lh_companies lh_teams lh_users lh_tasks lh_posts lh_roles lh_role_user lh_images lh_tags
              lh_taggables lh_custom_primary_keys lh_categories lh_comments].freeze

  class Record < ActiveRecord::Base
    self.abstract_class = true
  end

  class Company < Record
    self.table_name = 'lh_companies'
    has_many :users
  end

  class Team < Record
    self.table_name = 'lh_teams'
    has_many :users
  end

  class User < Record
    self.table_name = 'lh_users'
    belongs_to :company, optional: true
    belongs_to :team, optional: true
    has_many :tasks
    has_many :posts
    has_many :role_users
    has_many :roles, through: :role_users
    has_many :roles_pivot, class_name: 'LH::RoleUser'
    has_many :custom_primary_keys

    scope :named, -> { where.not(name: nil) }

    # Set to make destroys fail, as a `deleting` listener returning false does in Laravel.
    class_attribute :refuse_destroy, default: false
    before_destroy { throw :abort if self.class.refuse_destroy }
  end

  class Task < Record
    self.table_name = 'lh_tasks'
    belongs_to :user, optional: true
    has_one :post
    has_one :image, as: :imageable
    has_many :images, as: :imageable
    has_many :taggables, as: :taggable
    has_many :tags, through: :taggables
  end

  class Post < Record
    self.table_name = 'lh_posts'
    belongs_to :task, optional: true
    belongs_to :user, optional: true
    has_many :comments
  end

  class Comment < Record
    self.table_name = 'lh_comments'
    belongs_to :post, optional: true
  end

  class Role < Record
    self.table_name = 'lh_roles'
    has_many :role_users
    has_many :users, through: :role_users
  end

  # The role_user pivot, with its `meta` column.
  class RoleUser < Record
    self.table_name = 'lh_role_user'
    belongs_to :user, optional: true
    belongs_to :role, optional: true
  end

  RoleUserPivot = RoleUser

  class Image < Record
    self.table_name = 'lh_images'
    belongs_to :imageable, polymorphic: true, optional: true

    # Counts saves, so a test can tell model events fired.
    class_attribute :saves, default: 0
    after_save { self.class.saves += 1 }
  end

  class Tag < Record
    self.table_name = 'lh_tags'
    has_many :taggables
    has_many :tasks, through: :taggables, source: :taggable, source_type: 'LH::Task'
  end

  class Taggable < Record
    self.table_name = 'lh_taggables'
    belongs_to :tag
    belongs_to :taggable, polymorphic: true
  end

  class Category < Record
    self.table_name = 'lh_categories'
    self.primary_key = 'category_id'
  end

  class CustomPrimaryKey < Record
    self.table_name = 'lh_custom_primary_keys'
    self.primary_key = 'custom_primary_key_id'
    belongs_to :user, optional: true
  end

  # Empty every table and restart its ids at 1, as PHP Lighthouse's tests
  # expect of a fresh database.
  def self.reset!
    connection = Record.connection
    TABLES.each { |table| connection.execute("DELETE FROM #{table}") }
    connection.execute("DELETE FROM sqlite_sequence WHERE name IN (#{TABLES.map { |t| "'#{t}'" }.join(', ')})")
  end
end

# Shared setup for the ported PHP Lighthouse integration tests.
RSpec.shared_context 'with PHP Lighthouse models' do
  before do
    LH.reset!
    Lighthouse.configure { |c| c.resolver_namespaces = ['LH'] }
  end

  let(:schema) { build_schema(sdl, dataloader: true) }

  # The SQL statements run inside the block (schema introspection excluded).
  def queries_in
    sql = []
    subscriber = ActiveSupport::Notifications.subscribe('sql.active_record') do |*, payload|
      sql << payload[:sql] unless payload[:name] == 'SCHEMA' || payload[:sql].match?(/\A\s*(PRAGMA|SELECT sqlite_version)/)
    end
    yield
    sql
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  def graphql(query, variables = {})
    result = schema.execute(query, variables: variables).to_h
    @last_result = result
    result
  end

  # PHP Lighthouse's assertJson: `expected` is a subset of the response.
  def expect_data(result, expected)
    expect(result['errors']).to be_nil, -> { "unexpected errors: #{result['errors'].inspect}" }
    expect(result['data']).to include_json_subset(expected)
  end

  def error_messages(result)
    (result['errors'] || []).map { |e| e['message'] }
  end
end

# Matches when every key/value of `expected` appears in `actual`, recursively;
# arrays must match element-wise and in length.
RSpec::Matchers.define :include_json_subset do |expected|
  match { |actual| JsonSubset.match?(expected, actual) }
  failure_message { |actual| "expected #{actual.inspect}\nto include #{expected.inspect}" }
end

module JsonSubset
  module_function

  def match?(expected, actual)
    case expected
    when Hash then actual.is_a?(Hash) && expected.all? { |k, v| actual.key?(k.to_s) && match?(v, actual[k.to_s]) }
    when Array then actual.is_a?(Array) && expected.size == actual.size && expected.zip(actual).all? { |e, a| match?(e, a) }
    else expected == actual
    end
  end
end
