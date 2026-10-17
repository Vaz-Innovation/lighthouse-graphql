# frozen_string_literal: true

require 'active_support/cache'

module Lighthouse
  # Convenience entrypoint: `Lighthouse.configure { |c| c.resolver_namespaces = [...] }`.
  def self.configure(&block)
    Config.configure(&block)
  end

  module Config
    # Where each kind of class a schema refers to by name is looked up. Query and
    # mutation fields resolve to GraphQL::Schema::Resolver / Mutation classes,
    # builders compose onto a relation, validators check arguments: distinct
    # contracts, so distinct namespaces (app/graphql/queries, .../mutations, ...).
    DEFAULT_NAMESPACES = {
      queries: ['Queries'],
      mutations: ['Mutations'],
      builders: ['Builders'],
      validators: ['Validators'],
      events: ['Events']
    }.freeze

    # Every setting reset! forgets, so the next read falls back to its default.
    SETTINGS = %i[
      sdl_folder resolver_namespaces namespaces cache_store transactional_mutations pagination_default_count pagination_max_count
      schema_cache schema_cache_path watch_sdl persisted_queries persisted_queries_store persisted_queries_ttl
      persisted_queries_manifest persisted_queries_only on_error directive_map authenticated_user policy_user authorizer
    ].freeze

    class << self
      attr_writer :sdl_folder, :resolver_namespaces, :on_error, :authenticated_user, :policy_user, :authorizer, :cache_store,
                  :transactional_mutations, :schema_cache, :watch_sdl, :persisted_queries, :persisted_queries_store, :persisted_queries_only

      def sdl_folder
        @sdl_folder ||= (defined?(Rails) && Rails.respond_to?(:root) ? Rails.root.join('graphql').to_s : nil)
      end

      def directive_map = @directive_map ||= {}

      # Namespaces tried (in order) when resolving a class name from a directive
      # argument, e.g. `@field(resolver: "ContactPerson")` or `@all(model: "X")`.
      # Keeping this in config means the library holds no app-specific namespace
      # and can be extracted into a gem as-is.
      def resolver_namespaces
        @resolver_namespaces ||= ['App::Graphql']
      end

      # { queries:, mutations:, builders:, validators: } => [namespace, ...].
      # Assigning a partial hash overrides only the kinds it names.
      def namespaces
        @namespaces ||= DEFAULT_NAMESPACES.transform_values(&:dup)
      end

      def namespaces=(overrides)
        @namespaces = namespaces.merge(overrides.to_h.transform_keys(&:to_sym).transform_values { |v| Array(v) })
      end

      # Store backing @cache and @clearCache. Defaults to Rails.cache.
      def cache_store
        @cache_store ||=
          if defined?(Rails) && Rails.respond_to?(:cache) && Rails.cache
            Rails.cache
          else
            ActiveSupport::Cache::MemoryStore.new
          end
      end

      # --- Scale options: all off by default ----------------------------------
      #
      # schema_cache          cache the built schema document in tmp/cache (SchemaCache)
      # schema_cache_path     where; default Rails.root/tmp/cache/lighthouse
      # watch_sdl             reload the app (and so the schema) when a .graphql file changes
      # persisted_queries     accept Apollo's Automatic Persisted Queries (PersistedQueries)
      # persisted_queries_store     where APQ keeps queries; default cache_store
      # persisted_queries_ttl       how long they live there (seconds; nil: until evicted)
      # persisted_queries_manifest  a manifest of trusted operations, served by hash
      # persisted_queries_only      reject any operation not in the manifest
      attr_accessor :schema_cache_path, :persisted_queries_ttl, :persisted_queries_manifest

      def schema_cache = @schema_cache || false
      def watch_sdl = @watch_sdl || false
      def persisted_queries = @persisted_queries || false
      def persisted_queries_only = @persisted_queries_only || false

      def persisted_queries_store
        @persisted_queries_store || cache_store
      end

      # Pagination defaults, overridden by a directive's defaultCount / maxCount.
      # Without a default count, paginated fields require `first`.
      attr_accessor :pagination_default_count, :pagination_max_count

      # Run @create/@update/... in a database transaction, so a failing record
      # (e.g. the third of five in @createMany) leaves nothing behind.
      def transactional_mutations
        @transactional_mutations.nil? || @transactional_mutations
      end

      # Hook invoked when a directive/resolver swallows an error. Defaults to
      # re-raising in test (so failures surface) and logging otherwise. Override
      # via `Lighthouse.configure { |c| c.on_error = ->(e, ctx) { ... } }`.
      def on_error
        @on_error ||= Defaults.on_error
      end

      def handle_error(error, context = nil)
        on_error.call(error, context)
      end

      # --- Authorization seams (used by @guard / @can) -------------------------
      # The library stays framework-agnostic: how to read the authenticated user
      # and how to check an ability are both configurable. The defaults work with
      # a `current_user`/`pundit_user` context and Pundit.

      # Returns the authenticated user from the GraphQL context (nil if none).
      def authenticated_user
        @authenticated_user ||= ->(ctx) { ctx && (ctx[:current_user] || ctx['current_user']) }
      end

      # The "user" object passed to the authorizer (e.g. Pundit's user context).
      # Defaults to ctx[:pundit_user], falling back to the authenticated user.
      def policy_user
        @policy_user ||= lambda do |ctx|
          (ctx && (ctx[:pundit_user] || ctx['pundit_user'])) || authenticated_user.call(ctx)
        end
      end

      # Checks an ability: `->(user, record, ability, args = []) { true/false }`.
      # `record` may be a model class (@canModel). `args` carries the @can*
      # `args:` values and, with `injectArgs: true`, the field's arguments first.
      # Defaults to Pundit: `Pundit.policy!(user, record).<ability>?(*args)`.
      def authorizer = @authorizer ||= Defaults.authorizer

      def configure
        yield(self) if block_given?
      end

      def [](key)
        public_send(key)
      end

      def reset!
        SETTINGS.each { |setting| instance_variable_set("@#{setting}", nil) }
      end
    end

    # The callables the authorizer and on_error settings fall back to.
    module Defaults
      module_function

      def authorizer
        lambda do |user, record, ability, args = []|
          raise 'Lighthouse: configure `Config.authorizer` to use the @can* directives (Pundit not detected).' unless defined?(::Pundit)

          check = ::Pundit.policy!(user, record).method("#{ability}?")
          check.arity.zero? ? check.call : check.call(*args)
        end
      end

      def on_error
        lambda do |error, _context|
          if defined?(Rails) && Rails.respond_to?(:env) && Rails.env.test?
            raise error
          elsif defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger
            Rails.logger.warn("[Lighthouse] #{error.class}: #{error.message}")
          else
            warn("[Lighthouse] #{error.class}: #{error.message}")
          end
        end
      end
    end
  end

  module GraphQL
    Config = Lighthouse::Config unless const_defined?(:Config, false)
  end
end
