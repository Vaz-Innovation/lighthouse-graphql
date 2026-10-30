# frozen_string_literal: true

# Before anything defines `Rails` (the generator spec does): Pundit loads its
# Railtie when it sees one.
require 'pundit'
require 'dry/validation'
require 'lighthouse-graphql'
require 'active_record'
require 'graphql'

# In-memory database + a couple of ActiveRecord models so directive resolvers
# (filters, ordering, federation reference lookup) can be exercised without a
# host Rails app.
ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: ':memory:')
ActiveRecord::Schema.verbose = false
ActiveRecord::Schema.define do
  create_table :widgets, force: true do |t|
    t.string :name
    t.string :email
    t.integer :rank
  end

  create_table :posts, force: true do |t|
    t.string :title
    t.text :body
    t.integer :author_id
    t.boolean :published, default: false
  end
end

# The abstract base a host Rails app's models inherit from.
class ApplicationRecord < ActiveRecord::Base
  self.abstract_class = true
end

# A plain test model used by the argument-builder / ordering specs.
class Widget < ApplicationRecord
end

# A model with validations, for the mutation, authorization and cache specs.
class Post < ApplicationRecord
  validates :title, presence: true, length: { maximum: 20 }

  def self.published = where(published: true)
end

Dir[File.join(__dir__, 'support', '**', '*.rb')].each { |f| require f }

RSpec.configure do |config|
  config.expect_with(:rspec) { |c| c.syntax = :expect }
  config.disable_monkey_patching!
  config.order = :random
  config.before do
    Widget.delete_all
    Post.delete_all
    # Raw SQL: paranoia turns delete_all into a soft delete.
    %w[soft_tasks paranoid_items discard_items scheduled_posts soft_projects search_posts].each do |table|
      ActiveRecord::Base.connection.execute("DELETE FROM #{table}")
    end
    Lighthouse::GraphQL::Caching.store.clear
  end
  config.after do
    Lighthouse::Config.reset!
    Lighthouse::Events.reset!
  end
  Kernel.srand config.seed
end
