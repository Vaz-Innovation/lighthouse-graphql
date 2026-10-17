# frozen_string_literal: true

class GraphqlController < ApplicationController
  # If this endpoint is called from outside this domain, null the session
  # instead of failing CSRF verification:
  # protect_from_forgery with: :null_session

  include Lighthouse::GraphQL::Controller

  lighthouse_schema AppSchema

  private

  # Read by @guard and the @can* directives — see config/initializers/lighthouse.rb.
  def graphql_context = { current_user: current_user }
end
