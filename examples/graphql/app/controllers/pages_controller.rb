# frozen_string_literal: true

# A page that arrives with its data, loaded the way the GraphQL endpoint would
# load it: lighthouse_execute builds the endpoint's context (the signed-in
# user, what @throttle reads), so the operation is guarded and throttled as a
# client's would be. See docs/getting-started.md.
class PagesController < ApplicationController
  include Lighthouse::GraphQL::Operations

  lighthouse_schema AppSchema

  def search
    result = lighthouse_execute('query Search($term: String!) { searchPosts(term: $term) { title } me { name } }',
                                variables: { term: params[:term] })
    return if performed? # @throttle answered 429

    render json: { preloaded: result }
  end

  private

  def graphql_context = { current_user: current_user }
end
