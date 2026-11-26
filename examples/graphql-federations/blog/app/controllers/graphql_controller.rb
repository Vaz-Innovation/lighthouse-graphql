# The subgraph's endpoint. Lighthouse's controller runs queries, persisted
# queries and batches, and answers subscriptions: the router's, whose updates go
# to its callback (BlogSchema uses CallbackSubscriptions), and Yoga's, over
# Server-Sent Events.
class GraphqlController < ApplicationController
  include Lighthouse::GraphQL::Controller

  lighthouse_schema BlogSchema

  private

  def graphql_context = { current_user: current_user }
end
