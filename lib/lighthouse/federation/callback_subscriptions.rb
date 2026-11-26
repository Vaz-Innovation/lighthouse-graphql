# frozen_string_literal: true

require 'json'
require 'net/http'
require 'concurrent'
require 'active_support/json'

# Federated subscriptions: a graphql-ruby subscription backend that delivers a
# subgraph's Subscription fields to Apollo Router through its HTTP callback
# protocol (https://www.apollographql.com/docs/graphos/routing/operations/subscriptions/callback-protocol).
# Clients subscribe through the router (WebSocket or multipart HTTP); the
# router asks the subgraph with an ordinary POST that carries
# `extensions.subscription` (callbackUrl, subscriptionId, verifier,
# heartbeatIntervalMs), and the subgraph sends every update to callbackUrl.
#
#   class AppSchema < Lighthouse::GraphQL::RbLightHouse.get_schema(...)
#     use Lighthouse::GraphQL::Federation::CallbackSubscriptions
#   end
#
# Lighthouse::GraphQL::Controller reads the extension. The subscription runs as
# any other: its class's `authorized?` / `authorize?`, then, the router having
# answered the protocol's `check`, it is kept, and the request answers
# `{ "data": null }`. `@broadcast` and `trigger` then reach it as they reach an
# ActionCable one: each update runs the subscriber's operation again, in its
# context, and goes to the router as a `next` message; one the router answers
# 404 (the client left) is dropped. Every subscription is sent the `check`
# heartbeat its router asks for, and a `complete` when it ends here
# (`unsubscribe`).
#
# It is graphql-ruby's ActionCableSubscriptions as well: a subscription without
# a callback, over Server-Sent Events (Lighthouse::GraphQL::EventStream, which
# GraphQL Yoga and Hive Gateway ask a subgraph for) or an Action Cable channel
# (WebSocket), is that backend's, and one trigger reaches all three.
#
# Subscriptions live in the process that received them, as ActionCable's do. A
# trigger from another process (a job, another Puma worker) reaches them
# through ActionCable's pubsub when the app has Action Cable (its cable.yml
# adapter: solid_cable, redis, postgresql), else only the triggering process'
# own callback subscriptions are updated. A restarted process loses its
# subscriptions: the router ends them when their heartbeats stop, and its
# clients subscribe again.
#
# Options: `client:` posts the messages (`post(url, body) -> status`, Net::HTTP
# by default), `tick:` how often, in seconds, due heartbeats are sent (1), and
# ActionCableSubscriptions' own.
class Lighthouse::GraphQL::Federation::CallbackSubscriptions < GraphQL::Subscriptions::ActionCableSubscriptions
  # Where the controller puts the router's extension, in the operation's context.
  CONTEXT_KEY = :lighthouse_subscription_callback

  HEADERS = { 'Content-Type' => 'application/json', 'subscription-protocol' => 'callback/1.0' }.freeze

  # The router's `extensions.subscription` for a subscription it asks for.
  Callback = Struct.new(:url, :id, :verifier, :heartbeat_ms, keyword_init: true) do
    # The extension of a request's `extensions`, or nil.
    def self.from_extensions(extensions)
      subscription = subscription_of(extensions)
      return if subscription.nil? || subscription[:callbackUrl].blank? || subscription[:subscriptionId].blank?

      new(url: subscription[:callbackUrl].to_s, id: subscription[:subscriptionId].to_s, verifier: subscription[:verifier].to_s,
          heartbeat_ms: subscription[:heartbeatIntervalMs].to_i)
    end

    # `extensions.subscription`, from a JSON string, a Hash or parameters.
    def self.subscription_of(extensions)
      extensions = JSON.parse(extensions) if extensions.is_a?(String) && !extensions.empty?
      extensions = extensions.to_unsafe_h if extensions.respond_to?(:to_unsafe_h)
      subscription = extensions.is_a?(Hash) ? extensions.with_indifferent_access[:subscription] : nil
      subscription.to_h.with_indifferent_access if subscription.respond_to?(:to_h)
    end

    def message(action, **rest)
      { kind: 'subscription', action: action, id: id, verifier: verifier, **rest }
    end
  end

  # Posts a message with Net::HTTP; answers the status.
  class NetHttpClient
    def initialize(open_timeout: 5, read_timeout: 10)
      @open_timeout = open_timeout
      @read_timeout = read_timeout
    end

    def post(url, body)
      uri = URI(url)
      Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https', open_timeout: @open_timeout, read_timeout: @read_timeout) do |http|
        http.post(uri.request_uri, body, HEADERS).code.to_i
      end
    end
  end

  # A kept subscription: its operation, its events and where its updates go.
  Entry = Struct.new(:query, :events, :callback, :due_at, keyword_init: true)

  # The context of an operation the router sent (`extensions` from its
  # request): what the backend keeps it by. Empty for any other.
  def self.context_for(extensions)
    callback = Callback.from_extensions(extensions)
    callback ? { CONTEXT_KEY => callback } : {}
  end

  # The body of the router's request once the subscription ran: `{ data: null }`,
  # with the operation's errors (an unauthorized subscriber, an invalid
  # operation); a 400 when the router refused the `check`. Nil for any other.
  def self.response(result)
    context = result.respond_to?(:context) ? result.context : nil
    callback = context && context[CONTEXT_KEY]
    return unless callback

    errors = result.to_h['errors']
    return [{ 'errors' => [{ 'message' => 'The router refused the subscription callback check.' }] }, 400] if context[:lighthouse_callback_refused]

    [errors ? { 'data' => nil, 'errors' => errors } : { 'data' => nil }, 200]
  end

  # Action Cable, when the app has it (ActionCableSubscriptions' `action_cable:`).
  def initialize(client: NetHttpClient.new, tick: 1, action_cable: (::ActionCable if defined?(::ActionCable)), **rest)
    super(action_cable: action_cable, **rest)
    @client = client
    @tick = tick
    @entries = Concurrent::Map.new
    @topics = Concurrent::Map.new
    @streams = Concurrent::Set.new
    @lock = Mutex.new
  end

  # The router's subscription ran: `check` its callback, then keep it. One over
  # SSE or a channel is ActionCableSubscriptions'; any other is refused.
  def write_subscription(query, events)
    callback = query.context[CONTEXT_KEY]
    return super if callback.nil? && query.context[:channel]
    return refuse(query) unless callback

    if send_message(callback, :check) == 204
      keep(query, events, callback)
    else
      query.context[:lighthouse_callback_refused] = true
    end
  end

  # Updates every subscription to the event's topic: through ActionCable's
  # pubsub, in every process, when it is there (ActionCableSubscriptions'
  # broadcast, which this process' callback subscriptions listen to as well).
  def execute_all(event, object)
    pubsub ? super : execute_topic(event.topic, object)
  end

  def read_subscription(subscription_id)
    entry = @entries[subscription_id]
    return super unless entry

    { query_string: entry.query.query_string, variables: entry.query.provided_variables, context: entry.query.context.to_h,
      operation_name: entry.query.operation_name }
  end

  # A `next` message with the update; a subscription the router no longer has is dropped.
  def deliver(subscription_id, result)
    entry = @entries[subscription_id]
    return super unless entry

    status = send_message(entry.callback, :next, payload: result.to_h.slice('data', 'errors'))
    drop(subscription_id) unless (200..299).cover?(status)
  end

  # Ended here (`unsubscribe`): the router is told it is `complete`.
  def delete_subscription(subscription_id)
    return super unless @entries.key?(subscription_id)

    entry = drop(subscription_id)
    send_message(entry.callback, :complete) if entry
  end

  # Sends the heartbeats that are due; the timer calls it every `tick` seconds.
  def heartbeat!(now = monotonic)
    @entries.each_pair do |id, entry|
      next if entry.callback.heartbeat_ms <= 0 || entry.due_at > now

      entry.due_at = next_heartbeat(entry.callback, now)
      drop(id) unless send_message(entry.callback, :check) == 204
    end
  end

  # The ids of the subscriptions this process keeps: the router's, then the others'.
  def subscription_ids = @entries.keys + @subscriptions.keys

  private

  def refuse(query)
    message = 'This subgraph delivers subscriptions through Apollo Router HTTP callbacks, Server-Sent Events ' \
              '(Accept: text/event-stream) or Action Cable: subscribe through one of them.'
    query.context.add_error(::GraphQL::ExecutionError.new(message))
  end

  def keep(query, events, callback)
    query.context[:subscription_id] = callback.id
    @entries[callback.id] = Entry.new(query: query, events: events, callback: callback, due_at: next_heartbeat(callback))
    events.each do |event|
      (@topics.compute_if_absent(event.topic) { Concurrent::Array.new }) << callback.id
      stream(event)
    end
    start_heartbeats
  end

  def execute_topic(topic, object)
    (@topics[topic] || []).dup.each do |id|
      entry = @entries[id]
      event = entry&.events&.find { |candidate| candidate.topic == topic }
      execute(id, event, object) if event
    end
  end

  # Forgets a subscription, without telling the router; answers its entry.
  def drop(subscription_id)
    entry = @entries.delete(subscription_id)
    entry&.events&.each { |event| @topics[event.topic]&.delete(subscription_id) }
    entry
  end

  # The router's status; 0 when it could not be reached.
  def send_message(callback, action, **rest)
    @client.post(callback.url, JSON.generate(callback.message(action.to_s, **rest)))
  rescue StandardError => e
    message = "Lighthouse: subscription callback #{action} to #{callback.url} failed: #{e.class}: #{e.message}"
    ::Rails.logger&.warn(message) if defined?(::Rails.logger)
    0
  end

  # ActionCable's pubsub, when the app has Action Cable configured; nil otherwise.
  def pubsub
    return unless @action_cable.respond_to?(:server)

    @action_cable.server.pubsub
  rescue StandardError
    nil
  end

  # Listens, once per process, to the broadcasting of a topic's events
  # (ActionCableSubscriptions'), for the callback subscriptions to it.
  def stream(event)
    adapter = pubsub
    return unless adapter && @streams.add?(event.topic)

    adapter.subscribe(stream_event_name(event), lambda { |message|
      execute_topic(event.topic, load_action_cable_message(ActiveSupport::JSON.decode(message), event.context))
    })
  end

  def start_heartbeats
    @lock.synchronize do
      return if @timer

      @timer = Concurrent::TimerTask.new(execution_interval: @tick) { heartbeat! }
      @timer.execute
    end
  end

  def next_heartbeat(callback, now = monotonic)
    now + (callback.heartbeat_ms / 1000.0)
  end

  def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
end
