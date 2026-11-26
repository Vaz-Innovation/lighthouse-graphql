# frozen_string_literal: true

require 'active_support/json'
require 'time'

# GraphQL over Server-Sent Events: the response of a request whose Accept names
# `text/event-stream`, in graphql-sse's distinct connections mode
# (https://github.com/enisdenjo/graphql-sse/blob/master/PROTOCOL.md), which
# GraphQL Yoga, Hive Gateway and @graphql-tools/executor-http speak. Each result
# is a `next` event, and a `complete` event ends the stream:
#
#   event: next
#   data: {"data":{"postCreated":{"title":"Hello"}}}
#
#   event: complete
#   data:
#
# A query or a mutation is one `next` and the `complete`. A subscription stays
# open: the stream stands for an Action Cable channel (`stream_from`, all that
# graphql-ruby's ActionCableSubscriptions asks of one), so the schema's one
# backend serves its subscriptions over WebSocket (a channel) and SSE alike, and
# a trigger reaches both through Action Cable's pubsub (cable.yml's adapter).
# Each update is a `next`; the subscription ending on the server
# (`unsubscribe`) is the `complete`; the client going away ends it here.
#
# Lighthouse::GraphQL::Controller answers with it, as Rails streams a template
# (`self.response_body =`): the server iterates `each` in the request's thread,
# which the stream keeps for as long as it is open (as ActionController::Live
# does), waiting for its updates and writing a comment every `keep_alive`
# seconds, which is how a client gone is found out. Each update runs in a
# thread of its own, inside the Rails app's executor, as Action Cable runs a
# channel's: its own connections, query cache and reloading.
class Lighthouse::GraphQL::EventStream
  Gone = Lighthouse::GraphQL::Incremental::Gone

  CONTENT_TYPE = 'text/event-stream'
  KEEP_ALIVE = ":\n\n"
  COMPLETE = "event: complete\ndata:\n\n"

  # The subscription the stream delivers, once `start` saw it kept.
  attr_reader :subscription_id

  # Does an Accept header take an event stream?
  def self.accepted?(accept)
    accept.to_s.split(',').any? { |type| type.split(';').first.to_s.strip.casecmp?(CONTENT_TYPE) }
  end

  # The headers of the response: as a multipart one's, uncached and unbuffered.
  def self.headers
    Lighthouse::GraphQL::Incremental::Multipart.headers("#{CONTENT_TYPE}; charset=utf-8").merge('Connection' => 'keep-alive')
  end

  # An event of the stream: `next` with a result, as its JSON.
  def self.event(result) = "event: next\ndata: #{ActiveSupport::JSON.encode(result)}\n\n"

  # The events of a stream's body, as a client reads them: each `next`'s result.
  def self.parse(body)
    body.to_s.split("\n\n").filter_map do |event|
      lines = event.lines.map(&:chomp)
      next unless lines.include?('event: next')

      JSON.parse(lines.grep(/\Adata:/).map { |line| line.delete_prefix('data:').strip }.join("\n"))
    end
  end

  # `pubsub`: what subscriptions listen to (Action Cable's, by default, when
  # one is asked for). `on_error` is told of an error that ended the stream on
  # its way, `on_end` that it ended.
  def initialize(schema, pubsub: nil, keep_alive: 12, on_error: nil, on_end: nil)
    @schema = schema
    @pubsub = pubsub
    @executor = ::Rails.application&.executor if defined?(::Rails) && ::Rails.respond_to?(:application)
    @keep_alive = keep_alive
    @on_error = on_error
    @on_end = on_end
    @listeners = []
    @items = []
    @lock = Mutex.new
    @arrived = ConditionVariable.new
  end

  # The operation's result: the stream's first event, if any, and whether it goes on.
  def start(result)
    hash = result.to_h
    @subscription_id = result.context[:subscription_id] if result.respond_to?(:context)
    @open = result.respond_to?(:subscription?) && result.subscription? && !@subscription_id.nil? && !hash.key?('errors')
    # A subscription's own request answers no data, unless its `subscribe` returned some.
    @first = @open && hash['data'].blank? ? nil : self.class.event(hash)
    self
  end

  # What graphql-ruby's ActionCableSubscriptions calls on a channel: listen to a
  # broadcasting, with the block (its message decoded by `coder`, when given)
  # or, without one, to send each message (JSON, then) to the client.
  def stream_from(broadcasting, callback = nil, coder: nil, &block)
    handler = block || callback
    coder ||= ActiveSupport::JSON unless handler
    listener = ->(message) { push([handler, coder ? coder.decode(message) : message]) }
    @lock.synchronize { @listeners << [broadcasting, listener] }
    pubsub.subscribe(broadcasting, listener)
  end

  # The body: the first event, then each update as it comes, until the
  # subscription ends or the client goes away.
  def each(&write)
    emit(write, @first) if @first
    until @done || !@open
      item = pop
      item ? handle(item, write) : emit(write, KEEP_ALIVE)
    end
    emit(write, COMPLETE)
  rescue Gone
    nil
  rescue StandardError => e
    @on_error&.call(e)
  ensure
    finish
  end

  # Stops listening, forgets the subscription and ends the request, once.
  def finish
    return if @finished

    @finished = true
    @done = true
    listeners = @lock.synchronize { @listeners.dup.tap { @listeners.clear } }
    listeners.each { |broadcasting, listener| pubsub.unsubscribe(broadcasting, listener) }
    @schema.subscriptions&.delete_subscription(@subscription_id) if @subscription_id
  ensure
    @lock.synchronize { @arrived.broadcast }
    @on_end&.call
  end

  def open? = @open && !@done

  private

  # A message to the client (no handler): its result is a `next`, its end the
  # `complete`. A broadcasting's (a handler) runs the update, which comes back as
  # a message to the client.
  def handle((handler, message), write)
    return update(handler, message) if handler
    return @done = true unless message.is_a?(Hash)

    emit(write, self.class.event(message['result'])) if message['result']
    @done = true if message['more'] == false
  end

  # Writes to the client: an error the server raises is the client gone.
  def emit(write, text)
    write.call(text)
  rescue StandardError
    raise Gone
  end

  def update(handler, message)
    run = -> { handler.call(message) }
    @executor ? Thread.new { @executor.wrap(&run) }.join : run.call
  rescue StandardError => e
    @on_error&.call(e)
  end

  def push(item)
    @lock.synchronize do
      @items << item
      @arrived.signal
    end
  end

  # The next item, or nil when none came for `keep_alive` seconds.
  def pop
    @lock.synchronize do
      @arrived.wait(@lock, @keep_alive) if @items.empty? && !@done
      @items.shift
    end
  end

  def pubsub
    @pubsub ||= begin
      unless defined?(::ActionCable) && ::ActionCable.respond_to?(:server)
        raise Lighthouse::DefinitionError,
              'A subscription over Server-Sent Events goes through Action Cable: add it to the app (cable.yml names its pubsub adapter).'
      end

      ::ActionCable.server.pubsub
    end
  end
end
