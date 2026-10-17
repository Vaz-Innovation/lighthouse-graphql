Rails.application.routes.draw do
  post '/graphql', to: 'graphql#execute'
  # GET serves persisted queries by hash, so CDNs can cache them (see config/initializers/lighthouse.rb).
  get '/graphql', to: 'graphql#execute'

  # The GraphiQL IDE, in development only: http://localhost:3000/graphiql
  get '/graphiql', to: 'graphiql#show', constraints: ->(_request) { Rails.env.development? }

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  get 'up' => 'rails/health#show', :as => :rails_health_check
end
