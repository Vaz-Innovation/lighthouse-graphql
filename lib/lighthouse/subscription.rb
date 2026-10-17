# frozen_string_literal: true

require 'active_support/concern'
require 'active_support/core_ext/class/attribute'

# PHP Lighthouse's subscription model, as a concern a plain graphql-ruby
# subscription includes. The class is written as graphql-ruby's guide has it,
# and gains the hooks of PHP Lighthouse's GraphQLSubscription, as
# `include Lighthouse::GraphQL::Controller` gives a controller its `execute`:
#
#   class Subscriptions::PostUpdated < GraphQL::Schema::Subscription
#     include Lighthouse::GraphQL::Subscription
#
#     argument :author_id, ID, required: false
#
#     def filter?(post, author_id: nil) = author_id.nil? || post.author_id.to_s == author_id
#   end
#
#   PHP Lighthouse                    here                                  graphql-ruby
#   authorize(Subscriber, Request)    authorize?(**args)                    authorized? (initial request only)
#   filter(Subscriber, $root)         filter?(root, **args)                 update returns NO_UPDATE when false
#   resolve($root, $args, ...)        resolve_payload(root, **args)         update's return value
#   encodeTopic / decodeTopic         self.topic_for(arguments:, field:, scope:)
#
# `object`, `context` and `field` are available in every hook, and `context`
# is the subscriber's: graphql-ruby stores it with the subscription and
# replays it for each update, so `context[:current_user]` is the subscriber.
#
# Precedence: the concern sits between the class and GraphQL::Schema::Subscription,
# so a class that defines `update` or `authorized?` itself wins, and its
# `filter?`, `resolve_payload` or `authorize?` are not called unless it calls
# `super`. Everything else graphql-ruby offers (`subscribe`, `unsubscribe`,
# `subscription_scope`, `ready?`) is untouched.
#
# Unlike a plain subscription, every subscriber of the field shares one topic
# (the field name and its scope, not its arguments), which is PHP Lighthouse's
# model: a trigger reaches all of them and `filter?` decides who gets it, from
# the subscriber's own arguments. `topic_by :arguments` turns graphql-ruby's
# exact-argument matching back on.
module Lighthouse::GraphQL::Subscription
  extend ActiveSupport::Concern

  included do
    unless self < ::GraphQL::Schema::Subscription
      raise Lighthouse::DefinitionError,
            "#{self} includes Lighthouse::GraphQL::Subscription, which is for subclasses of GraphQL::Schema::Subscription " \
            '(class Subscriptions::PostUpdated < GraphQL::Schema::Subscription).'
    end

    class_attribute :lighthouse_topic_by, instance_accessor: false, instance_predicate: false, default: :field
  end

  class_methods do
    # :field (the default) or :arguments. See `topic_for`. Inherited by subclasses.
    def topic_by(mode = nil)
      return lighthouse_topic_by unless mode

      raise ArgumentError, "topic_by takes :field or :arguments, not #{mode.inspect}" unless %i[field arguments].include?(mode)

      self.lighthouse_topic_by = mode
    end

    # The stream a subscription belongs to, and the one a trigger addresses.
    # Only the scope and the field by default: every subscriber is updated, and
    # `filter?` narrows it down. With `topic_by :arguments` it is
    # graphql-ruby's: the trigger's arguments must equal the subscriber's.
    def topic_for(arguments:, field:, scope:)
      return super if topic_by == :arguments

      ::GraphQL::Subscriptions::Serialize.dump_recursive([scope, field.graphql_name])
    end

    # The arguments @broadcast triggers this subscription with, for the
    # `root` a mutation returned. Matter only with `topic_by :arguments`,
    # where they must equal the subscribers' arguments.
    def trigger_arguments(_root, _context)
      {}
    end

    # The `scope:` @broadcast triggers this subscription with. Needed when the
    # class declares `subscription_scope`.
    def trigger_scope(_root, _context)
      nil
    end
  end

  # May this client subscribe? Return false (or raise a GraphQL::ExecutionError)
  # to refuse. Called once, with the subscription request, not for each update.
  def authorize?(**_args)
    true
  end

  # Should this subscriber receive the broadcast of `root`? `args` are the
  # arguments the client subscribed with; `context` is theirs.
  def filter?(_root, **_args)
    true
  end

  # The value an update resolves the field with; the broadcast root by default.
  def resolve_payload(root, **_args)
    root
  end

  def authorized?(**args)
    return super if context.query.subscription_update? || authorize?(**args)

    [false, Lighthouse::AuthorizationError.new('Unauthorized subscription request.')]
  end

  def update(**args)
    filter?(object, **args) ? resolve_payload(object, **args) : ::GraphQL::Schema::Subscription::NO_UPDATE
  end
end

# What a Subscription field with no class of its own resolves to: graphql-ruby's
# subscription with the concern, so every subscriber gets every broadcast
# unchanged.
Lighthouse::GraphQL::Subscription::Default = Class.new(GraphQL::Schema::Subscription) do
  include Lighthouse::GraphQL::Subscription
end
