Rails.application.routes.draw do
  # The subgraph's endpoint, which the router calls: queries, mutations, `_service` and `_entities`.
  post '/graphql', to: 'graphql#execute'
  get '/graphql', to: 'graphql#execute'

  get 'up' => 'rails/health#show', :as => :rails_health_check
end
