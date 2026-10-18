# frozen_string_literal: true

class GraphqlController < ApplicationController
  # If this endpoint is called from outside this domain, null the session
  # instead of failing CSRF verification:
  # protect_from_forgery with: :null_session

  include Lighthouse::GraphQL::Controller

  lighthouse_schema AppSchema

  # The endpoint's own limit, Rails' rate_limit (a 429 past it). Fields with
  # @throttle count apart, each under its own name (the field, by default).
  rate_limit to: 600, within: 1.minute, name: 'endpoint'

  private

  # Read by @guard and the @can* directives — see config/initializers/lighthouse.rb.
  def graphql_context = { current_user: current_user }

  # What @throttle(with: "too_many_requests") calls past a field's limit, as
  # rate_limit's with: instead of its default (a 429 Rails renders), a 429 with
  # the body of a GraphQL error. It renders, so the request ends there.
  def too_many_requests
    render json: { errors: [{ message: 'Too many requests. Try again later.' }] }, status: :too_many_requests
  end
end
