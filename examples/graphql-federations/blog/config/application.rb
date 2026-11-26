require_relative 'boot'

require 'rails'
require 'active_model/railtie'
require 'active_job/railtie'
require 'active_record/railtie'
require 'action_controller/railtie'
require 'action_cable/engine'
require 'global_id/railtie'

Bundler.require(*Rails.groups)

# The blog subgraph: posts, comments and tags, and the subscriptions that follow
# them. Its schema is graphql/schema.graphql; the gateway (Apollo Router,
# ../router) composes it with the accounts subgraph's.
module Blog
  class Application < Rails::Application
    config.load_defaults 8.1
    config.api_only = true
    # Posts and comments are entities of the Authored interface, whose key must
    # tell them apart across both tables: UUIDs.
    config.generators { |g| g.orm :active_record, primary_key_type: :uuid }
  end
end
