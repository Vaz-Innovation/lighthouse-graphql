# frozen_string_literal: true

# What every class resolving a Query field shares: Lighthouse resolves
# Query.latestPosts to Resolvers::LatestPosts by convention, and every such
# class inherits from this one. graphql-ruby's `graphql:install` writes the
# same class.
class Resolvers::BaseResolver < GraphQL::Schema::Resolver
end
