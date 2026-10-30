# frozen_string_literal: true

require 'active_support/duration'
require 'active_support/notifications'
require_relative 'base'

# @throttle — Rails' `rate_limit` on one field: at most `maxAttempts` calls (its
# to:) every `decayMinutes` (its within:), counted as ActionController::RateLimiting
# counts them, with its options:
#
#   by:      who the client is, as rate_limit's by: a path in the context, as
#            @inject's ("current_user.id"); the client's IP by default.
#   with:    a method of the controller to call past the limit, as rate_limit's
#            with:. One that renders or redirects ends the request with its
#            response, as a before_action that renders does; one that returns lets
#            the call through. Without it, rate_limit's default: raise
#            ActionController::TooManyRequests, which Rails answers with a 429
#            (`head :too_many_requests` on a Rails without it, 7.2). Without Action
#            Pack at all, the field fails: "Rate limit for Query.x exceeded. Try again later."
#            So does it where the response is already on its way (a later part of a
#            streamed @defer response, see Defer): it can no longer be a 429, nor
#            anything `with:` would render, so `with:` is not called.
#   name:    as rate_limit's: the field by default (Query.x). Fields, and the
#            controller's own `rate_limit`, of the same name count together.
#   prefix:  as rate_limit's scope: the controller's path by default.
#
# The count lives in the controller's cache_store (config.action_controller.cache_store,
# Rails.cache unless set), under rate_limit's key, and a refused call is instrumented
# as rate_limit's (rate_limit.action_controller). The controller concern puts the
# controller in the context (:lighthouse_controller); outside one, the count lives in
# Rails.cache, with no scope. Outermost: refused calls never reach @guard or the resolver.
#
#   type Mutation {
#     login(email: String!, password: String!): User @throttle(maxAttempts: 5)
#     search(term: String!): [Post!]! @throttle(maxAttempts: 30, decayMinutes: 0.5, by: "current_user.id")
#   }
class Lighthouse::GraphQL::DirectiveResolvers::ThrottleDirectiveResolver < Lighthouse::GraphQL::DirectiveResolvers::BaseDirectiveResolver
  def self.directive_name = 'throttle'

  def self.definition
    <<~GRAPHQL.chomp
      """
      Sets rate limit to access the field, as Rails' rate_limit does for an action.
      """
      directive @throttle(
        "As rate_limit's name: fields, and the controller's own rate_limit, of the same name count together. Defaults to the field."
        name: String
        "Maximum number of attempts in a specified time interval."
        maxAttempts: Int = 60
        "Time in minutes to reset attempts."
        decayMinutes: Float = 1.0
        "As rate_limit's scope: what the count is shared across. Defaults to the controller's path."
        prefix: String
        "As rate_limit's by: who the client is, a path in the context (\\"current_user.id\\"). Defaults to the client's IP."
        by: String
        "As rate_limit's with: the controller's method to call past the limit. Defaults to rate_limit's: a 429."
        with: String
      ) on FIELD_DEFINITION
    GRAPHQL
  end

  def define_resolver(target_type_class)
    me = self
    inner = capture_inner(target_type_class)
    location = "#{target_type_class.graphql_name}.#{@field_def.name}"
    limit = {
      to: directive_arg('maxAttempts') || 60, within: ActiveSupport::Duration.build(((directive_arg('decayMinutes') || 1.0) * 60).ceil),
      by: directive_arg('by'), with: directive_arg('with'), name: directive_arg('name') || location, scope: directive_arg('prefix')
    }

    install(target_type_class, lambda do |obj, args, ctx|
      me.hit!(limit, ctx, location)
      inner.call(obj, args, ctx)
    end)
  end

  # ActionController::RateLimiting#rate_limiting, for one call of the field.
  def hit!(limit, ctx, location)
    controller = ctx[:lighthouse_controller]
    key = { scope: limit[:scope] || controller&.controller_path, name: limit[:name], by: client(limit, ctx) }
    cache_key = ['rate-limit', *key.values].compact.join(':')
    count = increment(store(controller), cache_key, limit[:within], location)
    refuse(controller, limit, location, key.merge(count: count, cache_key: cache_key)) if count && count > limit[:to]
  end

  # A :null_store keeps no count, so the limit never applies: say so, once per field.
  def self.warn_null_store(location)
    @warned ||= Set.new
    return unless @warned.add?(location)

    message = "Lighthouse: @throttle on #{location} counts nothing, as the cache store is a :null_store. " \
              'Set config.action_controller.cache_store (or config.cache_store), as for Rails\' rate_limit.'
    defined?(Rails) && Rails.logger ? Rails.logger.warn(message) : warn(message)
  end

  private

  # rate_limit's by: the value at `by`'s path in the context, else the client's IP.
  def client(limit, ctx)
    limit[:by] ? Lighthouse::Support::Arguments.dig(ctx, limit[:by]).first : ctx[:remote_ip]
  end

  # Where rate_limit counts: the controller's cache_store; Rails.cache outside one.
  def store(controller)
    controller.respond_to?(:cache_store) ? controller.cache_store : Lighthouse::GraphQL::Caching.store
  end

  # The count after this call. A store whose increment does not create the key
  # (ActiveSupport before 7.1) starts it with a write.
  def increment(store, key, within, location)
    self.class.warn_null_store(location) if store.is_a?(::ActiveSupport::Cache::NullStore)
    store.increment(key, 1, expires_in: within) || (store.write(key, 1, expires_in: within) && 1)
  end

  # Past the limit: instrumented as rate_limit's, around `with`, after which a
  # response `with` performed ends the request, as a before_action's would.
  def refuse(controller, limit, location, counted)
    committed = controller&.performed?
    payload = { request: controller&.request, to: limit[:to], within: limit[:within], **counted }
    ActiveSupport::Notifications.instrument('rate_limit.action_controller', payload) { limited(controller, limit[:with], location, committed) }
    raise Lighthouse::GraphQL::Controller::Performed if controller&.performed?
  end

  # The controller's `with` method, else rate_limit's default `with`; a field error once the
  # response has `committed` (performed? before this call: streaming).
  def limited(controller, with, location, committed)
    unless committed
      return call_with(controller, with, location) if with && controller
      raise ::ActionController::TooManyRequests if defined?(::ActionController::TooManyRequests)
      return controller.head(:too_many_requests) if controller
    end

    raise ::GraphQL::ExecutionError, "Rate limit for #{location} exceeded. Try again later."
  end

  def call_with(controller, with, location)
    unless controller.respond_to?(with, true)
      raise Lighthouse::DefinitionError, "@throttle(with: \"#{with}\") on #{location}: #{controller.class} has no method #{with}."
    end

    controller.send(with)
  end
end
