# frozen_string_literal: true

require 'active_job'

# Triggers a subscription from a queue (@broadcast with shouldQueue, or
# Config.queue_broadcasts). Loaded on first use — the activejob gem is
# optional — so it is autoloaded rather than listed in rb_lighthouse.rb.
# The schema is passed by name, and the root (an Active Record model, say)
# through ActiveJob's serialization. (A gem has no ApplicationJob to inherit from.)
class Lighthouse::GraphQL::BroadcastJob < ActiveJob::Base # rubocop:disable Rails/ApplicationJob
  def perform(schema_name, subscription, trigger_arguments, root, scope = nil)
    Lighthouse::GraphQL::Broadcasting.trigger(schema_name.constantize, subscription, trigger_arguments, root, scope)
  end
end
