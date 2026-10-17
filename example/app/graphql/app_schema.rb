# frozen_string_literal: true

# Executable schema built by Lighthouse from the SDL in graphql/. The
# Dataloader batches relationship loads (@hasMany, @belongsTo, ...) to avoid N+1.
# ActionCableSubscriptions delivers the Subscription type's fields (see
# app/channels/graphql_channel.rb); `@broadcast` on a mutation triggers them.
AppSchema = Lighthouse::GraphQL::RbLightHouse.get_schema(
  options: {
    using: { GraphQL::Dataloader => {}, GraphQL::Subscriptions::ActionCableSubscriptions => {} }
    # base_types: { object: Types::BaseObject } # your graphql-ruby base classes
  }
)
