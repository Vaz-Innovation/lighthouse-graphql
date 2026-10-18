# frozen_string_literal: true

# What every type class shares. The schema builds the SDL's object types from
# it (base_types' object:, in app_schema.rb). A subclass that includes
# Lighthouse::GraphQL::Type (Types::PostType) resolves fields of its type, such as
# Post.readingTime with Types::PostType#reading_time. graphql-ruby's
# `graphql:install` writes the same class.
class Types::BaseObject < GraphQL::Schema::Object
end
