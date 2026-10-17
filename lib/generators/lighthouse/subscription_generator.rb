# frozen_string_literal: true

require_relative 'class_generator'

# `rails generate lighthouse:subscription PostUpdated` — a
# GraphQL::Schema::Subscription that `Subscription.postUpdated` resolves to by
# convention. With `--lighthouse`, the class also includes
# Lighthouse::GraphQL::Subscription (PHP Lighthouse's authorize?/filter?/resolve_payload hooks).
class Lighthouse::Generators::SubscriptionGenerator < Lighthouse::Generators::ClassGenerator
  desc 'Generate a subscription class (GraphQL::Schema::Subscription) in app/graphql/subscriptions.'

  class_option :lighthouse, type: :boolean, default: false,
                            desc: "Include Lighthouse::GraphQL::Subscription: PHP Lighthouse's authorize?/filter?/resolve_payload hooks"

  private

  def kind = :subscriptions

  def body
    options[:lighthouse] ? lighthouse_body : plain_body
  end

  def plain_body
    <<~RUBY
      # Resolves Subscription.#{field_name}. Keyword arguments are the field's arguments in
      # snake_case; `object` and `context` are available. `context` is the subscriber's:
      # graphql-ruby stores it with the subscription and replays it for every update.
      class #{class_basename} < GraphQL::Schema::Subscription
        # Runs for the subscription request and again for every update. Raise a
        # GraphQL::ExecutionError to refuse with a message (false refuses silently).
        def authorized?(**args)
          true
        end

        # The subscription request. Its return value answers the client right away;
        # the default returns nothing (:no_response).
        #
        # def subscribe(**args)
        #   :no_response
        # end

        # Each update; `object` is what the mutation broadcast (@broadcast passes its
        # result). The default returns `object`. Return NO_UPDATE to skip this
        # subscriber, or another value to send that instead.
        #
        # def update(**args)
        #   return NO_UPDATE unless context[:current_user]
        #
        #   object
        # end

        # What @broadcast triggers this subscription with, for the `root` a mutation
        # returned. graphql-ruby updates only the subscribers whose arguments equal
        # these, so return one value for every argument the field takes (`{}` for
        # a field with none).
        def self.trigger_arguments(root, context)
          {}
        end
      end
    RUBY
  end

  def lighthouse_body
    <<~RUBY
      # Resolves Subscription.#{field_name}. A graphql-ruby subscription with PHP Lighthouse's
      # hooks: every subscriber of the field gets every broadcast, and `filter?` decides.
      # All hooks are optional; `object` and `context` (the subscriber's) are available.
      class #{class_basename} < GraphQL::Schema::Subscription
        include Lighthouse::GraphQL::Subscription

        # May this client subscribe? Keyword arguments are the field's arguments.
        def authorize?(**args)
          true
        end

        # Should this subscriber receive the broadcast of `root`?
        def filter?(root, **args)
          true
        end

        # What the update resolves the field with.
        def resolve_payload(root, **args)
          root
        end
      end
    RUBY
  end

  def field_name = class_basename.camelize(:lower)

  def usage
    "Subscription.#{field_name} resolves to #{full_class_name} — add the field to your SDL, " \
      "and trigger it from a mutation with @broadcast(subscription: \"#{field_name}\") or `schema.subscriptions.trigger`."
  end
end
