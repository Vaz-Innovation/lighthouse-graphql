# frozen_string_literal: true

# Lighthouse configuration. Every option is optional; the defaults are shown.
# Reference: https://github.com/Vaz-Innovation/lighthouse-graphql/blob/main/docs/configuration.md
Lighthouse.configure do |config|
  # Folder the *.graphql schema files are loaded from.
  # config.sdl_folder = Rails.root.join('graphql').to_s

  # Where classes named by the schema are looked up, by kind. A Query or Mutation
  # field without a resolving directive resolves by convention: Query.latestPosts
  # to Resolvers::LatestPosts (a Resolvers::BaseResolver), Mutation.publishPost
  # to Mutations::PublishPost (a GraphQL::Schema::Mutation). @builder classes
  # come from :builders and @validator contracts from :validators. Generate them
  # with `rails g lighthouse:query|mutation|builder|validator Name`.
  # config.namespaces = {
  #   queries: ['Resolvers'], mutations: ['Mutations'], builders: ['Builders'], validators: ['Validators'],
  #   analyzers: ['Analyzers']
  # }

  # Namespaces tried, in order, for models (@all(model: "User")) and for
  # @field(resolver:) on types other than Query and Mutation. Fully-qualified
  # names (containing `::`) are used as-is.
  # config.resolver_namespaces = ['App::Graphql']

  # Store for @cache and @clearCache.
  # config.cache_store = Rails.cache

  # Run @create/@update/@createMany/@updateMany in a database transaction.
  # config.transactional_mutations = true

  # --- For large schemas and high traffic (all off by default) ---------------
  # This example app turns them on, each where it is meant to be used.
  # Cache the built schema document in tmp/cache, keyed by the SDL and
  # everything that shapes it; warm it at deploy with `bin/rails lighthouse:cache`.
  config.schema_cache = Rails.env.production?

  # Reload the app (and so the schema) when a .graphql file changes.
  config.watch_sdl = Rails.env.development?

  # Automatic Persisted Queries (Apollo's protocol). Add a GET route too, so
  # hashed queries can be cached by CDNs: get "/graphql", to: "graphql#execute"
  # This app turns it on, with the GET route in config/routes.rb.
  config.persisted_queries = true
  config.persisted_queries_ttl = 1.week.to_i
  # A manifest of trusted operations from your client build, served by hash;
  # with persisted_queries_only, nothing else may run.
  # This app's (persisted-queries.json) is checked in CI by `bin/rails lighthouse:persisted_queries:verify`.
  config.persisted_queries_manifest = Rails.root.join('persisted-queries.json')
  # config.persisted_queries_only = Rails.env.production?

  # Called when a directive or resolver swallows an error. The default raises in
  # test and logs otherwise.
  # config.on_error = ->(error, _context) { Rails.error.report(error) }

  # Authorization seams used by @guard and the @can* directives (Pundit by default).
  # config.authenticated_user = ->(ctx) { ctx[:current_user] }
  # config.policy_user = ->(ctx) { ctx[:pundit_user] || ctx[:current_user] }
  # config.authorizer = ->(user, record, ability, args = []) { Pundit.policy!(user, record).public_send("#{ability}?", *args) }
end

# Register app-defined directives and federation reference resolvers inside
# to_prepare, so they reference reloadable constants and run before the schema
# is built. See docs/custom-directives.md and docs/federation.md.
# Rails.application.config.to_prepare do
#   Lighthouse::DirectiveRegistry.register(Directives::Upcase)
#   Lighthouse::ReferenceResolver.register('User') { |ref, _ctx| User.find_by(id: ref['id']) }
# end
