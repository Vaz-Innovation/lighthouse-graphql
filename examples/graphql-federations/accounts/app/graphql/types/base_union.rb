# frozen_string_literal: true

module Types
  class BaseUnion < GraphQL::Schema::Union
    # Lighthouse's: the class of the SDL type of its name lends that type its methods.
    include Lighthouse::GraphQL::Type
    edge_type_class(Types::BaseEdge)
    connection_type_class(Types::BaseConnection)
  end
end
