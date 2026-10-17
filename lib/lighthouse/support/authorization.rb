# frozen_string_literal: true

# Thin wrapper over the configurable authorization seams, used by the @guard
# and @can directives so they stay framework-agnostic.
module Lighthouse::Support::Authorization
  module_function

  def authenticated_user(context)
    Lighthouse::Config.authenticated_user.call(context)
  end

  def authenticated?(context)
    !authenticated_user(context).nil?
  end

  # Returns true/false for `ability` against `record` (an instance, or a model
  # class) for the current policy user. Defaults to Pundit (see
  # Config#authorizer). `args` reach the authorizer only when given, so a
  # three-argument authorizer keeps working for checks without them.
  def authorized?(context, record, ability, args = [])
    user = Lighthouse::Config.policy_user.call(context)
    authorizer = Lighthouse::Config.authorizer
    args.empty? ? authorizer.call(user, record, ability) : authorizer.call(user, record, ability, args)
  end
end
