# frozen_string_literal: true

# Executable schema built by Lighthouse from the SDL in graphql/. The
# Dataloader batches relationship loads (@hasMany, @belongsTo, ...) to avoid N+1.
# ActionCableSubscriptions delivers the Subscription type's fields (see
# app/channels/graphql_channel.rb); `@broadcast` on a mutation triggers them.
# base_types names the base classes: every class a Query, Mutation or Subscription
# field resolves to must inherit from its kind's, and a Subscription field with no
# class of its own resolves with Subscriptions::BaseSubscription.
AppSchema = Lighthouse::GraphQL::RbLightHouse.get_schema(
  options: {
    using: { GraphQL::Dataloader => {}, GraphQL::Subscriptions::ActionCableSubscriptions => {} },
    base_types: {
      resolver: Resolvers::BaseResolver,
      mutation: Mutations::BaseMutation,
      subscription: Subscriptions::BaseSubscription
      # object: Types::BaseObject, ... # graphql-ruby's base classes of the SDL's types
    }
  }
)

# Refuse expensive queries before they run: graphql-ruby scores each query from
# the fields it selects. Paginated fields scale by `first`, Tag.posts names the
# analyzer that sets its cost (@complexity, app/graphql/analyzers) and
# Resolvers::SearchPosts declares its own `complexity`. Guide: ../docs/security.md
AppSchema.max_complexity(1000)
