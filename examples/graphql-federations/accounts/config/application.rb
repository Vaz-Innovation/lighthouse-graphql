require_relative 'boot'

require 'rails'
require 'active_model/railtie'
require 'active_job/railtie'
require 'active_record/railtie'
require 'active_storage/engine'
require 'action_controller/railtie'
require 'global_id/railtie'

Bundler.require(*Rails.groups)

# The accounts subgraph: who the users are, their avatars, and what they like.
# Its schema is graphql/schema.graphql; the gateway (Apollo Router, ../router)
# composes it with the blog subgraph's.
module Accounts
  class Application < Rails::Application
    config.load_defaults 8.1
    config.api_only = true
  end
end
