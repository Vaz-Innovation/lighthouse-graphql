# frozen_string_literal: true

require_relative 'base'

# @throttle — rate-limit a field per client, as PHP Lighthouse's directive (and
# Laravel's ThrottleRequests): at most `maxAttempts` calls every `decayMinutes`,
# counted in Config.cache_store. A client is the signed-in user, else the
# context's :remote_ip (Lighthouse::GraphQL::Controller sets it), else "guest".
# Past the limit the field fails with "Rate limit for Query.x exceeded. Try
# again later." Outermost: refused calls never reach @guard or the resolver.
#
#   type Mutation {
#     login(email: String!, password: String!): User @throttle(maxAttempts: 5)
#     search(term: String!): [Post!]! @throttle(name: "search", maxAttempts: 30, decayMinutes: 0.5)
#   }
class Lighthouse::GraphQL::DirectiveResolvers::ThrottleDirectiveResolver < Lighthouse::GraphQL::DirectiveResolvers::BaseDirectiveResolver
  def self.directive_name = 'throttle'

  def self.definition
    <<~GRAPHQL.chomp
      """
      Sets rate limit to access the field. Does the same as ThrottleRequests Laravel Middleware.
      """
      directive @throttle(
        "A name shared by the fields that count together. Defaults to the field."
        name: String
        "Maximum number of attempts in a specified time interval."
        maxAttempts: Int = 60
        "Time in minutes to reset attempts."
        decayMinutes: Float = 1.0
        "Prefix to distinguish several field groups."
        prefix: String
      ) on FIELD_DEFINITION
    GRAPHQL
  end

  def define_resolver(target_type_class)
    me = self
    inner = capture_inner(target_type_class)
    location = "#{target_type_class.graphql_name}.#{@field_def.name}"
    bucket = "#{directive_arg('prefix')}#{directive_arg('name') || location}"
    max_attempts = directive_arg('maxAttempts') || 60
    decay = ((directive_arg('decayMinutes') || 1.0) * 60).ceil

    install(target_type_class, lambda do |obj, args, ctx|
      me.hit!(bucket, ctx, max_attempts, decay, location)
      inner.call(obj, args, ctx)
    end)
  end

  def hit!(bucket, ctx, max_attempts, decay, location)
    key = "lighthouse:throttle:#{bucket}:#{client(ctx)}"
    store = Lighthouse::GraphQL::Caching.store
    self.class.warn_null_store(location) if store.is_a?(::ActiveSupport::Cache::NullStore)
    attempts = store.increment(key, 1, expires_in: decay) || (store.write(key, 1, expires_in: decay) && 1)
    raise ::GraphQL::ExecutionError, "Rate limit for #{location} exceeded. Try again later." if attempts > max_attempts
  end

  # A :null_store keeps no count, so the limit never applies: say so, once per field.
  def self.warn_null_store(location)
    @warned ||= Set.new
    return unless @warned.add?(location)

    message = "Lighthouse: @throttle on #{location} counts nothing, as the cache store is a :null_store. Set Config.cache_store."
    defined?(Rails) && Rails.logger ? Rails.logger.warn(message) : warn(message)
  end

  private

  def client(ctx)
    user = Lighthouse::Support::Authorization.authenticated_user(ctx)
    return "user:#{user.respond_to?(:id) ? user.id : user}" if user

    ip = ctx.respond_to?(:[]) ? ctx[:remote_ip] : nil
    ip ? "ip:#{ip}" : 'guest'
  end
end
