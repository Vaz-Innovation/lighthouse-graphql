# frozen_string_literal: true

module Types
  class BaseScalar < GraphQL::Schema::Scalar
    # Lighthouse's: the class of the SDL type of its name lends that type its methods.
    include Lighthouse::GraphQL::Type
  end
end
