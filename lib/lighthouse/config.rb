# frozen_string_literal: true

module Lighthouse
  # Convenience entrypoint: `Lighthouse.configure { |c| c.resolver_namespaces = [...] }`.
  def self.configure(&block)
    Config.configure(&block)
  end

  module Config
    # Where each kind of class a schema refers to by name is looked up. Query and
    # mutation fields resolve to GraphQL::Schema::Resolver / Mutation classes,
    # builders compose onto a relation, validators check arguments: distinct
    # contracts, so distinct namespaces (app/graphql/resolvers, .../mutations, ...).
    DEFAULT_NAMESPACES = {
      queries: ['Resolvers'],
      mutations: ['Mutations'],
      builders: ['Builders'],
      validators: ['Validators'],
      events: ['Events'],
      subscriptions: ['Subscriptions'],
      analyzers: ['Analyzers'],
      types: ['Types']
    }.freeze

    # Every setting reset! forgets, so the next read falls back to its default.
    SETTINGS = %i[
      schema_path ide_helper resolver_namespaces namespaces transactional_mutations pagination_default_count pagination_max_count
      schema_cache schema_cache_path watch_sdl persisted_queries persisted_queries_store persisted_queries_ttl
      persisted_queries_manifest persisted_queries_only on_error directive_map authenticated_user policy_user authorizer
      feature_checker feature_actor
      convert_empty_strings_to_null
      soft_deletes
      queue_broadcasts broadcast_queue
      global_id
      schema_output
    ].freeze

    class << self
      attr_writer :schema_path, :ide_helper, :resolver_namespaces, :on_error, :authenticated_user, :policy_user, :authorizer,
                  :transactional_mutations, :schema_cache, :watch_sdl, :persisted_queries, :persisted_queries_store, :persisted_queries_only,
                  :queue_broadcasts,
                  :convert_empty_strings_to_null, :feature_checker, :feature_actor, :global_id

      # A file development keeps the client schema in (SchemaPrinter): a path
      # (under Rails.root; `.json` for the introspection result), or
      # { path:, schema: 'AppSchema' }. nil (the default): none.
      attr_accessor :schema_output

      # The schema's entrypoint, as PHP Lighthouse's `schema_path`: the one file
      # the schema is read from, importing the others (`#import user.graphql`,
      # `#import blog/*.graphql`; see SchemaStitcher). RAILS_ROOT/graphql/schema.graphql
      # by default.
      def schema_path
        @schema_path ||= (::Rails.root.join('graphql/schema.graphql').to_s if defined?(::Rails) && ::Rails.respond_to?(:root) && ::Rails.root)
      end

      # The folder of the schema's entrypoint, which watch_sdl watches.
      def schema_directory
        schema_path && File.dirname(schema_path.to_s)
      end

      # Rewrite the IDE helper files (schema-directives.graphql,
      # programmatic-types.graphql) on boot and on every reload. nil (the
      # default): in development, when the app has a graphql.config.yml.
      def ide_helper
        return @ide_helper unless @ide_helper.nil?

        defined?(::Rails) && ::Rails.respond_to?(:env) && ::Rails.env.development? && ::Rails.root &&
          File.exist?(::Rails.root.join('graphql.config.yml'))
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

      # --- Subscriptions (used by @broadcast) ----------------------------------
      #
      # queue_broadcasts  perform @broadcast triggers in a Lighthouse::GraphQL::BroadcastJob
      #                   (ActiveJob) instead of inline; a directive's shouldQueue overrides it
      # broadcast_queue   the job's queue name; nil: ActiveJob's default
      attr_accessor :broadcast_queue

      def queue_broadcasts = @queue_broadcasts || false

      # --- Scale options: all off by default ----------------------------------
      #
      # schema_cache          cache the built schema document in tmp/cache (SchemaCache)
      # schema_cache_path     where; default Rails.root/tmp/cache/lighthouse
      # watch_sdl             reload the app (and so the schema) when a .graphql file changes
      # persisted_queries     accept Apollo's Automatic Persisted Queries (PersistedQueries)
      # persisted_queries_store     where APQ keeps queries; default Rails.cache
      # persisted_queries_ttl       how long they live there (seconds; nil: until evicted)
      # persisted_queries_manifest  a manifest of trusted operations, served by hash: a JSON file,
      #                             a Hash, or a callable answering either
      # persisted_queries_only      reject any operation not in the manifest
      attr_accessor :schema_cache_path, :persisted_queries_ttl, :persisted_queries_manifest

      def schema_cache = @schema_cache || false
      def watch_sdl = @watch_sdl || false
      def persisted_queries = @persisted_queries || false
      def persisted_queries_only = @persisted_queries_only || false

      # Make every field behave as if it carried @convertEmptyStringsToNull. Read
      # when the schema is built, so set it in an initializer.
      def convert_empty_strings_to_null = @convert_empty_strings_to_null || false

      # Encodes and decodes Relay global ids (@globalId, @node): `encode(type, id)`
      # and `decode(global_id)` -> [type, id]. Base64 of "Type:id" by default.
      def global_id = @global_id || Lighthouse::GraphQL::GlobalId

      def persisted_queries_store
        @persisted_queries_store || Lighthouse::GraphQL::Caching.store
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

      # --- Feature flags (used by @feature) ------------------------------------

      # Is a feature on? `->(name, actor, ctx) { true/false }`, with the feature's
      # name as written in the SDL. Defaults to Flipper: `Flipper.enabled?(name.to_sym, actor)`.
      def feature_checker = @feature_checker ||= Lighthouse::GraphQL::FeatureDirective.default_checker

      # The actor features are checked for: `->(ctx) { actor }` (a Flipper actor
      # answers `flipper_id`; nil checks the feature globally). Defaults to the
      # authenticated user.
      def feature_actor = @feature_actor ||= ->(ctx) { authenticated_user.call(ctx) }

      # --- Soft deletes (used by @softDeletes, @trashed, @restore, @forceDelete) ---

      # Teaches Lighthouse what "trashed" means. Any object answering
      # `soft_deletes?(model)`, `only_trashed(relation)`, `with_trashed(relation)`,
      # `without_trashed(relation)`, `restore(record)` and `force_delete(record)`.
      # Defaults to detecting paranoia, then discard, then a `deleted_at` column
      # per model (Support::SoftDeletes::Auto); `Support::SoftDeletes::Column.new(:archived_at)`
      # is one for another column.
      attr_accessor :soft_deletes

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
