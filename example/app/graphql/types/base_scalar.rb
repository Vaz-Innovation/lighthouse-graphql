# frozen_string_literal: true

# What every scalar class shares, as graphql-ruby's `graphql:install` writes it.
# The schema builds the SDL's scalars from it (base_types' scalar:, in
# app_schema.rb), and Types::DateTimeType inherits from it.
class Types::BaseScalar < GraphQL::Schema::Scalar
end
