# frozen_string_literal: true

# What every class resolving a Mutation field shares: Lighthouse resolves
# Mutation.publishPost to Mutations::PublishPost by convention, and every such
# class inherits from this one. The SDL declares the arguments, so it is a
# plain GraphQL::Schema::Mutation; the GraphQL::Schema::RelayClassicMutation
# graphql-ruby's `graphql:install` writes (one `input:` argument) works too.
class Mutations::BaseMutation < GraphQL::Schema::Mutation
end
