# Resolves Subscription.postCreated. Keyword arguments are the field's arguments in
# snake_case; `object` and `context` are available. `context` is the subscriber's:
# graphql-ruby stores it with the subscription and replays it for every update.
#
# Written with graphql-ruby's own hooks, `authorized?` and `update`: defined here,
# they win over the ones of the concern Subscriptions::BaseSubscription includes.
class Subscriptions::PostCreated < Subscriptions::BaseSubscription
  # Runs for the subscription request and again for every update.
  def authorized?(**)
    raise GraphQL::ExecutionError, 'Sign in to subscribe to new posts.' unless context[:current_user]

    true
  end

  # Each update; `object` is the post createPost returned (@broadcast passes its
  # result). A draft is for its author and admins only (PostPolicy#update?), so
  # everyone else is skipped with NO_UPDATE.
  def update(**)
    return object if object.published? || PostPolicy.new(context[:current_user], object).update?

    NO_UPDATE
  end

  # The field takes no arguments, so every subscriber matches an empty trigger.
  def self.trigger_arguments(_post, _context)
    {}
  end
end
