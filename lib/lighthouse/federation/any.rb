# frozen_string_literal: true

require 'active_support/hash_with_indifferent_access'

# The spec's `scalar _Any`: an entity representation the gateway sends to
# `Query._entities`, `{ "__typename": "User", "id": "1" }`. Read as a Hash
# whose keys are strings or symbols alike, as the resolvers that receive it
# (Entities) read it.
class Lighthouse::GraphQL::Federation::Any < GraphQL::Schema::Scalar
  graphql_name '_Any'

  def self.coerce_input(value, _context)
    raise ::GraphQL::CoercionError, 'An entity representation is an object with a __typename.' unless value.is_a?(Hash)

    ActiveSupport::HashWithIndifferentAccess.new(value)
  end

  def self.coerce_result(value, _context) = value
end
