# The GraphiQL IDE, routed in development only (config/routes.rb). Its assets
# come from a CDN, so this API-only app needs no asset pipeline for it.
class GraphiqlController < ApplicationController
  # API controllers render JSON only; this one also renders its HTML view.
  include ActionView::Layouts

  DEFAULT_QUERY = <<~GRAPHQL.freeze
    # Welcome to the Lighthouse example API.
    #
    # Docs (top left) lists every field, including the types Lighthouse
    # generates; Explorer builds queries by clicking.
    #
    # To sign in, run `bin/rails db:seed` and paste one of the tokens it prints
    # in the Headers tab below:
    #   { "Authorization": "Bearer <token>" }

    query LatestPosts {
      posts(first: 5) {
        data {
          title
          author { name }
          tags { name }
          commentsCount
        }
        paginatorInfo { total currentPage lastPage }
      }
    }
  GRAPHQL

  def show
    render :show, formats: :html, locals: { endpoint: graphql_path, default_query: DEFAULT_QUERY }
  end
end
