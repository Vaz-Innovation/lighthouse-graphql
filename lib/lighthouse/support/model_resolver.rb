# frozen_string_literal: true

module Lighthouse
  module Support
    # Resolves a class name string (from a directive argument such as
    # `@field(resolver: "Resolvers::ContactPerson")` or `@all(model: "Contact")`)
    # into an actual constant.
    #
    # The list of namespaces to try is configurable via
    # `Lighthouse::Config.resolver_namespaces`, so the library does not need to
    # know any app-specific namespace. This is a key seam for extracting the
    # library into a standalone gem.
    module ModelResolver
      module_function

      DEFAULT_NAMESPACES = ['App::Graphql'].freeze

      def namespaces
        if defined?(Lighthouse::Config) &&
           Lighthouse::Config.respond_to?(:resolver_namespaces) &&
           Lighthouse::Config.resolver_namespaces
          Array(Lighthouse::Config.resolver_namespaces)
        else
          DEFAULT_NAMESPACES
        end
      end

      def constantize(name)
        return nil unless name

        raw = name.to_s.strip
        return nil if raw.empty?

        candidates_for(raw).each do |candidate|
          klass = try_constantize(candidate)
          return klass if klass
        end

        nil
      end

      def candidates_for(raw)
        if raw.include?('::')
          [raw]
        else
          namespaces.map { |ns| "#{ns}::#{raw}" } + [raw]
        end
      end

      def try_constantize(candidate)
        ActiveSupport::Dependencies.constantize(candidate)
      rescue NameError, LoadError
        begin
          Object.const_get(candidate)
        rescue NameError
          nil
        end
      end
    end
  end
end
