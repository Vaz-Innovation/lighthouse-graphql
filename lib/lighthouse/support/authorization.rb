# frozen_string_literal: true

module Lighthouse
  module Support
    # Thin wrapper over the configurable authorization seams, used by the @guard
    # and @can directives so they stay framework-agnostic.
    module Authorization
      module_function

      def authenticated_user(context)
        Lighthouse::Config.authenticated_user.call(context)
      end

      def authenticated?(context)
        !authenticated_user(context).nil?
      end

      # Returns true/false for `ability` against `record` for the current policy
      # user. Defaults to Pundit (see Config#authorizer).
      def authorized?(context, record, ability)
        user = Lighthouse::Config.policy_user.call(context)
        Lighthouse::Config.authorizer.call(user, record, ability)
      end
    end
  end
end
