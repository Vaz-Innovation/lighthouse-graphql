# frozen_string_literal: true

# GraphqlController, streaming: the response of a query with @defer or @stream goes
# out as multipart/mixed parts (use Lighthouse::GraphQL::Defer in AppSchema). Only
# the requests of a client that prefers multipart/mixed are routed here
# (Lighthouse::GraphQL::Defer::Streaming, config/routes.rb), so only they run in
# ActionController::Live's thread; every other request runs in GraphqlController,
# as before. Guide: ../../docs/performance.md#deferring-fields-experimental
class GraphqlStreamingController < GraphqlController
  include ActionController::Live

  # One endpoint: rate_limit and @throttle count both controllers' requests together
  # (their scope is the controller's path).
  def self.controller_path = superclass.controller_path
end
