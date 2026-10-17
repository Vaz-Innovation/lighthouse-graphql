# frozen_string_literal: true

require_relative 'class_generator'

# `rails generate lighthouse:subscription PostUpdated` — a
# Lighthouse::GraphQL::Subscription that `Subscription.postUpdated` resolves
# to by convention.
class Lighthouse::Generators::SubscriptionGenerator < Lighthouse::Generators::ClassGenerator
  desc 'Generate a subscription class (Lighthouse::GraphQL::Subscription) in app/graphql/subscriptions.'

  private

  def kind = :subscriptions

  def body
    <<~RUBY
      # Resolves Subscription.#{class_basename.camelize(:lower)}. Every hook is optional; `object`
      # (the broadcast root, in filter? and resolve_payload) and `context`
      # (the subscriber's) are available.
      class #{class_basename} < Lighthouse::GraphQL::Subscription
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

  def usage
    "Subscription.#{class_basename.camelize(:lower)} resolves to #{full_class_name} — add the field to your SDL, " \
      'and trigger it from a mutation with @broadcast(subscription: ' \
      "\"#{class_basename.camelize(:lower)}\") or `schema.subscriptions.trigger`."
  end
end
