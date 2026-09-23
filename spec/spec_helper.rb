# frozen_string_literal: true

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
end

# A plain test model used by the argument-builder / ordering specs.
class Widget < ActiveRecord::Base
end

Dir[File.join(__dir__, 'support', '**', '*.rb')].sort.each { |f| require f }

RSpec.configure do |config|
  config.expect_with(:rspec) { |c| c.syntax = :expect }
  config.disable_monkey_patching!
  config.order = :random
  config.before { Widget.delete_all }
  Kernel.srand config.seed
end
