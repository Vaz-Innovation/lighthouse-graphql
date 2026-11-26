# frozen_string_literal: true

module Subscriptions
  # What every class resolving a Subscription field shares. The concern is PHP
  # Lighthouse's model: every subscriber of a field gets every broadcast, and the
  # class's `filter?` decides who receives it. A subclass that defines
  # graphql-ruby's own `authorized?` or `update` keeps them, and `topic_by
  # :arguments` brings back graphql-ruby's exact-argument matching.
  class BaseSubscription < GraphQL::Schema::Subscription
    include Lighthouse::GraphQL::Subscription
  end
end
