# frozen_string_literal: true

# The end-to-end suite of the federated example: it drives Apollo Router in
# front of the accounts and blog subgraphs, each a Rails app running Lighthouse
# (spec/support/stack.rb starts them all once). Needs Docker and, to compose
# the supergraph, rover (https://www.apollographql.com/docs/rover/getting-started).
require 'securerandom'
require_relative 'support/stack'
require_relative 'support/client'
require_relative 'support/graph_helpers'
require_relative 'support/callback_endpoint'
require_relative 'support/event_stream'

RSpec.configure do |config|
  config.expect_with(:rspec) { |c| c.syntax = :expect }
  config.disable_monkey_patching!
  config.order = :defined
  config.include GraphHelpers

  config.before(:suite) { Stack.start! }
end
