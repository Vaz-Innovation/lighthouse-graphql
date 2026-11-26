# The subgraph's endpoint. Lighthouse's controller runs queries, persisted
# queries and batches (the router batches its fetches to a subgraph when told to).
class GraphqlController < ApplicationController
  include Lighthouse::GraphQL::Controller

  lighthouse_schema AccountsSchema

  private

  def graphql_context = { current_user: current_user }
end
