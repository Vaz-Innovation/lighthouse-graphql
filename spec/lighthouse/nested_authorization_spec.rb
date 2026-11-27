# frozen_string_literal: true

ActiveRecord::Schema.define do
  create_table :nested_auth_users, force: true do |t|
    t.string :name
  end

  create_table :nested_auth_posts, force: true do |t|
    t.string :title
    t.boolean :published, default: false
    t.integer :author_id
  end

  create_table :nested_auth_comments, force: true do |t|
    t.string :body
    t.integer :post_id
    t.integer :author_id
  end
end

class NestedAuthUser < ApplicationRecord
  has_many :comments, class_name: 'NestedAuthComment', foreign_key: :author_id, inverse_of: false
end

class NestedAuthPost < ApplicationRecord
  scope :published, -> { where(published: true) }
end

class NestedAuthComment < ApplicationRecord
  belongs_to :post, class_name: 'NestedAuthPost', optional: true
  # The rule on the association: every load of it, batched or not, keeps it.
  belongs_to :published_post, -> { published }, class_name: 'NestedAuthPost', foreign_key: :post_id, optional: true, inverse_of: false
end

# Users are NestedAuthUser records (or nil): a post is visible when published, or to its author.
class NestedAuthPostPolicy
  attr_reader :user, :record

  def initialize(user, record)
    @user = user
    @record = record
  end

  def show? = record.published || record.author_id == user&.id

  class Scope
    def initialize(user, scope)
      @user = user
      @scope = scope
    end

    def resolve = @scope.where(published: true).or(@scope.where(author_id: @user&.id))
  end
end

class Builders::NestedAuthPolicyScope
  def self.call(relation, _args, context) = Pundit.policy_scope!(context[:current_user], relation)
end

# A rule on a root field does not follow the records a relation reaches
# (docs/authorization.md, "Records reached through a relation"): each way to
# put it where every path goes through it.
RSpec.describe 'Authorization of records reached through a relation' do
  let(:schema) do
    build_schema(<<~GRAPHQL, dataloader: true)
      type Query {
        posts: [Post!]! @all(model: "NestedAuthPost", scopes: ["published"])
        users: [User!]! @all(model: "NestedAuthUser")
      }

      type User @model(class: "NestedAuthUser") {
        name: String
        comments: [Comment!]! @hasMany
      }

      type Comment @model(class: "NestedAuthComment") {
        body: String
        post: Post @belongsTo
        publishedPost: Post @belongsTo
        scopedPost: Post @belongsTo(relation: "post", scopes: ["published"])
        policyPost: Post @belongsTo(relation: "post") @builder(class: "NestedAuthPolicyScope")
        checkedPost: Post @belongsTo(relation: "post") @canResolved(ability: "show", action: RETURN_VALUE)
      }

      type Post @model(class: "NestedAuthPost") {
        title: String
      }
    GRAPHQL
  end

  let!(:ada) { NestedAuthUser.create!(name: 'Ada') }
  let!(:grace) { NestedAuthUser.create!(name: 'Grace') }

  before do
    live = NestedAuthPost.create!(title: 'Live', published: true, author_id: ada.id)
    draft = NestedAuthPost.create!(title: 'Draft', published: false, author_id: ada.id)
    [live, draft].each { |post| NestedAuthComment.create!(body: "On #{post.title}", post_id: post.id, author_id: grace.id) }
  end

  after { [NestedAuthComment, NestedAuthPost, NestedAuthUser].each(&:delete_all) }

  # The titles each comment's field answers, for Grace's comments, as `user` sees them.
  def titles(field, user: grace)
    result = schema.execute("{ users { name comments { body #{field} { title } } } }", context: { current_user: user })
    expect(result['errors']).to be_nil
    result['data']['users'].find { |u| u['name'] == 'Grace' }['comments'].to_h { |c| [c['body'], c.dig(field, 'title')] }
  end

  it 'leaves drafts out of the root field, and a plain relation walks back to one' do
    roots = schema.execute('{ posts { title } }', context: { current_user: grace })['data']['posts']

    expect(roots).to eq([{ 'title' => 'Live' }])
    expect(titles('post')).to eq('On Live' => 'Live', 'On Draft' => 'Draft')
  end

  it 'keeps a scope on the association at any depth, in one query for every comment' do
    queries = []
    count = ->(*, payload) { queries << payload[:sql] if payload[:sql].include?('nested_auth_posts') }

    seen = ActiveSupport::Notifications.subscribed(count, 'sql.active_record') { titles('publishedPost') }

    expect(seen).to eq('On Live' => 'Live', 'On Draft' => nil)
    expect(queries.size).to eq(1)
  end

  it "applies the field's scopes:" do
    expect(titles('scopedPost')).to eq('On Live' => 'Live', 'On Draft' => nil)
  end

  it "applies a @builder on a relation field: Pundit's scope, for the user asking" do
    expect(titles('policyPost')).to eq('On Live' => 'Live', 'On Draft' => nil)
    expect(titles('policyPost', user: ada)).to eq('On Live' => 'Live', 'On Draft' => 'Draft')
  end

  it 'checks each record with @canResolved, after it loads' do
    expect(titles('checkedPost')).to eq('On Live' => 'Live', 'On Draft' => nil)
    expect(titles('checkedPost', user: ada)).to eq('On Live' => 'Live', 'On Draft' => 'Draft')
  end
end
