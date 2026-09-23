# frozen_string_literal: true

module Lighthouse
  # Convenience entrypoint: `Lighthouse.configure { |c| c.resolver_namespaces = [...] }`.
  def self.configure(&block)
    Config.configure(&block)
  end

  module Config
    class << self
      attr_writer :sdl_folder, :resolver_namespaces, :on_error,
                  :authenticated_user, :policy_user, :authorizer

      def sdl_folder
        @sdl_folder ||= (defined?(Rails) && Rails.respond_to?(:root) ? File.join(Rails.root, 'graphql') : nil)
      end

      def directive_map
        @directive_map ||= {}
      end

      # Namespaces tried (in order) when resolving a class name from a directive
      # argument, e.g. `@field(resolver: "ContactPerson")` or `@all(model: "X")`.
      # Keeping this in config means the library holds no app-specific namespace
      # and can be extracted into a gem as-is.
      def resolver_namespaces
        @resolver_namespaces ||= ['App::Graphql']
      end

      # Hook invoked when a directive/resolver swallows an error. Defaults to
      # re-raising in test (so failures surface) and logging otherwise. Override
      # via `Lighthouse.configure { |c| c.on_error = ->(e, ctx) { ... } }`.
      def on_error
        @on_error ||= default_on_error
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

      # Checks an ability: `->(user, record, ability) { true/false }`.
      # Defaults to Pundit: `Pundit.policy!(user, record).<ability>?`.
      def authorizer
        @authorizer ||= default_authorizer
      end

      def configure
        yield(self) if block_given?
      end

      def [](k)
        public_send(k)
      end

      def reset!
        @sdl_folder = nil
        @resolver_namespaces = nil
        @on_error = nil
        @directive_map = nil
        @authenticated_user = nil
        @policy_user = nil
        @authorizer = nil
      end

      private

      def default_authorizer
        lambda do |user, record, ability|
          unless defined?(::Pundit)
            raise 'Lighthouse: configure `Config.authorizer` to use @can (Pundit not detected).'
          end

          ::Pundit.policy!(user, record).public_send("#{ability}?")
        end
      end

      def default_on_error
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
