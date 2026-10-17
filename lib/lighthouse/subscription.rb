# frozen_string_literal: true

# The base class for the classes `Subscription.postUpdated` resolves to
# (Subscriptions::PostUpdated), with PHP Lighthouse's GraphQLSubscription hooks
# mapped onto graphql-ruby's GraphQL::Schema::Subscription:
#
#   PHP Lighthouse                    here                                  graphql-ruby
#   authorize(Subscriber, Request)    authorize?(**args)                    authorized? (initial request only)
#   filter(Subscriber, $root)         filter?(root, **args)                 update returns NO_UPDATE when false
#   resolve($root, $args, ...)        resolve_payload(root, **args)         update's return value
#   encodeTopic / decodeTopic         self.topic_for(arguments:, field:, scope:)
#
# `object`, `context` and `field` are available in every hook, and
# `context` is the subscriber's: graphql-ruby stores it with the subscription
# and replays it for each update, so `context[:current_user]` is the
# subscriber. Everything graphql-ruby offers still works: `subscribe` (an
# initial payload), `unsubscribe`, `subscription_scope`, `ready?`.
#
# Unlike a plain GraphQL::Schema::Subscription, every subscriber of the field
# shares one topic (the field name and its scope, not its arguments), which is
# PHP Lighthouse's model: a trigger reaches all of them and `filter?` decides
# who gets it, from the subscriber's own arguments. `topic_by :arguments` turns
# graphql-ruby's exact-argument matching back on.
class Lighthouse::GraphQL::Subscription < GraphQL::Schema::Subscription
  class << self
    # :field (the default) or :arguments. See `topic_for`.
    def topic_by(mode = nil)
      if mode
        raise ArgumentError, "topic_by takes :field or :arguments, not #{mode.inspect}" unless %i[field arguments].include?(mode)

        @topic_by = mode
      else
        @topic_by || (superclass.respond_to?(:topic_by) ? superclass.topic_by : :field)
      end
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
    filter?(object, **args) ? resolve_payload(object, **args) : NO_UPDATE
  end
end
