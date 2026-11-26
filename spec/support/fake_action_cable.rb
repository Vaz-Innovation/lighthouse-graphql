# frozen_string_literal: true

require 'active_support/json'

# What graphql-ruby's ActionCableSubscriptions and Lighthouse's EventStream use of
# Action Cable (the gem is not in the bundle): `server.broadcast`, which encodes the
# message as Action Cable does, and `server.pubsub`, an in-memory adapter that hands
# each broadcast to its listeners right away, in the broadcasting thread.
class FakeActionCable
  # Action Cable's pubsub adapter interface.
  class PubSub
    def initialize
      @listeners = Hash.new { |hash, key| hash[key] = [] }
      @lock = Mutex.new
    end

    def subscribe(channel, callback, success_callback = nil)
      @lock.synchronize { @listeners[channel] << callback }
      success_callback&.call
    end

    def unsubscribe(channel, callback)
      @lock.synchronize { @listeners[channel].delete(callback) }
    end

    def broadcast(channel, payload)
      @lock.synchronize { @listeners[channel].dup }.each { |callback| callback.call(payload) }
    end

    def channels = @lock.synchronize { @listeners.reject { |_, callbacks| callbacks.empty? }.keys }
  end

  # ActionCable.server.
  class Server
    attr_reader :pubsub

    def initialize
      @pubsub = PubSub.new
    end

    def broadcast(broadcasting, message, coder: ActiveSupport::JSON)
      pubsub.broadcast(broadcasting, coder.encode(message))
    end
  end

  attr_reader :server

  def initialize
    @server = Server.new
  end
end

# A subscriptions serializer (ActionCableSubscriptions' `serializer:`) that keeps the
# triggered objects in memory, where a Rails app's GlobalIDs would find them again.
module InMemorySerializer
  OBJECTS = Concurrent::Map.new

  module_function

  def dump(object) = object.object_id.to_s.tap { |key| OBJECTS[key] = object }

  def load(key) = OBJECTS.fetch(key)
end
