# frozen_string_literal: true

# The models and type classes of the type-level authorization specs.
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
