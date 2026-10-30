Rails.application.routes.draw do
  # A query with @defer or @stream is streamed, as multipart/mixed parts (AppSchema uses
  # Lighthouse::GraphQL::Defer); any other is answered whole.
  post '/graphql', to: 'graphql#execute'
  # GET serves persisted queries by hash, so CDNs can cache them (see config/initializers/lighthouse.rb),
  # and streams one that defers too.
  get '/graphql', to: 'graphql#execute'

  # A page preloading its data with lighthouse_execute (Lighthouse::GraphQL::Operations).
  get '/search', to: 'pages#search'

  # The GraphiQL IDE, in development only: http://localhost:3000/graphiql
  get '/graphiql', to: 'graphiql#show', constraints: ->(_request) { Rails.env.development? }

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  get 'up' => 'rails/health#show', :as => :rails_health_check
end
