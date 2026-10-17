# frozen_string_literal: true

# A GraphQL::Subscriptions backend that keeps everything in memory, for the
# specs (graphql-ruby's own test suite has one like it): it records what is
# registered (`registered`) and what is delivered to whom (`deliveries`).
# `use` it like any backend: `using: { InMemorySubscriptions => {} }`.
class InMemorySubscriptions < GraphQL::Subscriptions
  # [subscription_id, event] for every subscription written.
  attr_reader :registered

  # [subscription_id, result hash] for every update delivered.
  attr_reader :deliveries

  def initialize(schema:, **rest)
    super
    @queries = {}
    @events_by_topic = Hash.new { |hash, topic| hash[topic] = [] }
    @registered = []
    @deliveries = []
  end

  def write_subscription(query, events)
    subscription_id = query.context[:subscription_id] || build_id
    @queries[subscription_id] = {
      query_string: query.query_string,
      variables: query.provided_variables,
      context: query.context.to_h.except(:subscription_id),
      operation_name: query.operation_name
    }
    events.each do |event|
      @events_by_topic[event.topic] << subscription_id
      @registered << [subscription_id, event]
    end
  end

  def execute_all(event, object)
    @events_by_topic[event.topic].dup.each { |subscription_id| execute(subscription_id, event, object) }
  end

  def read_subscription(subscription_id)
    @queries[subscription_id]
  end

  def delete_subscription(subscription_id)
    @queries.delete(subscription_id)
    @events_by_topic.each_value { |ids| ids.delete(subscription_id) }
  end

  def deliver(subscription_id, result)
    @deliveries << [subscription_id, result.to_h]
  end

  def subscription_ids
    @queries.keys
  end

  def payloads_for(subscription_id)
    @deliveries.select { |id, _| id == subscription_id }.map { |_, result| result }
  end
end
