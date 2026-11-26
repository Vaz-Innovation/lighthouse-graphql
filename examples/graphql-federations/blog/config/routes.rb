Rails.application.routes.draw do
  # The subgraph's endpoint, which the router calls: queries, mutations, `_service`,
  # `_entities`, and the subscriptions it delivers through HTTP callbacks.
  post '/graphql', to: 'graphql#execute'
  get '/graphql', to: 'graphql#execute'

  get 'up' => 'rails/health#show', :as => :rails_health_check
end
