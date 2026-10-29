# frozen_string_literal: true

require_relative 'base'

# @broadcast — on a mutation (or any field), trigger a subscription once the
# field resolved successfully: its result is the root the subscribers'
# updates are resolved from, each passing through the subscription's
# `filter?`. A nil result or a GraphQL::ExecutionError (a failed mutation)
# broadcasts nothing; repeat the directive to trigger several subscriptions.
# See Lighthouse::GraphQL::Broadcasting for how it is triggered, and queued.
class Lighthouse::GraphQL::DirectiveResolvers::BroadcastDirectiveResolver < Lighthouse::GraphQL::DirectiveResolvers::BaseDirectiveResolver
  def self.directive_name = 'broadcast'

  def self.definition
    <<~GRAPHQL.chomp
      """
      Broadcast the result of the field to the subscribers of a subscription, once it resolved successfully.
      A null result, or an error, broadcasts nothing.
      """
      directive @broadcast(
        "The name of the subscription field to trigger."
        subscription: String!
        "Broadcast in a background job instead of in the request. Defaults to Config.queue_broadcasts."
        shouldQueue: Boolean
      ) repeatable on FIELD_DEFINITION
    GRAPHQL
  end

  def define_resolver(target_type_class)
    subscription = directive_arg('subscription')
    should_queue = directive_arg('shouldQueue')
    inner = capture_inner(target_type_class)

    install(target_type_class, lambda do |obj, args, ctx|
      result = inner.call(obj, args, ctx)
      unless result.nil? || result.is_a?(::GraphQL::ExecutionError)
        Lighthouse::GraphQL::Broadcasting.broadcast(ctx.schema, subscription, result, ctx, should_queue: should_queue)
      end
      result
    end)
  end
end
