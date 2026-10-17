# frozen_string_literal: true

# Executable schema built by Lighthouse from the SDL in graphql/. The
# Dataloader batches relationship loads (@hasMany, @belongsTo, ...) to avoid N+1.
AppSchema = Lighthouse::GraphQL::RbLightHouse.get_schema(
  options: {
    using: { GraphQL::Dataloader => {} }
    # base_types: { object: Types::BaseObject } # your graphql-ruby base classes
  }
)
