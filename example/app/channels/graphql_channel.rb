# Runs GraphQL operations sent over the socket, as graphql-ruby documents
# (https://graphql-ruby.org/subscriptions/action_cable_implementation.html).
# A subscription stays registered with AppSchema.subscriptions for as long as
# the socket is open, and each update is transmitted to the client as it comes.
class GraphqlChannel < ApplicationCable::Channel
  def subscribed
    @subscription_ids = []
  end

  def execute(data)
    result = AppSchema.execute(
      data['query'],
      variables: ensure_hash(data['variables']),
      operation_name: data['operationName'],
      # What GraphqlController#graphql_context holds (read by @guard, @can* and the
      # subscription classes: the subscriber's context is replayed for each update),
      # plus the channel ActionCableSubscriptions streams through.
      context: { current_user: current_user, channel: self }
    )

    @subscription_ids << result.context[:subscription_id] if result.context[:subscription_id]
    transmit({ result: result.to_h, more: result.subscription? })
  end

  def unsubscribed
    @subscription_ids.each { |id| AppSchema.subscriptions.delete_subscription(id) }
  end

  private

  def ensure_hash(param)
    case param
    when String then param.present? ? ensure_hash(JSON.parse(param)) : {}
    when Hash, ActionController::Parameters then param
    when nil then {}
    else raise ArgumentError, "Unexpected parameter: #{param}"
    end
  end
end
