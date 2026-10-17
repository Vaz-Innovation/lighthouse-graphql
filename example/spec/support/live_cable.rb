# A GraphqlChannel on ActionCable's real pub/sub (the `test` adapter of
# config/cable.yml, which is the async adapter underneath), not the stubbed
# streams of `type: :channel` specs. The streams ActionCableSubscriptions opens
# therefore work: a broadcast from a mutation reaches the channel through the
# event stream, the subscription is re-evaluated, and the update lands on the
# subscription's own stream, from which the channel transmits it. Delivery runs
# on ActionCable's threads, so the specs wait for it.
module LiveCable
  # One socket: the connection a client opens (its `current_user`) and its channel.
  class Client
    SUBSCRIPTION_STREAM = GraphQL::Subscriptions::ActionCableSubscriptions::SUBSCRIPTION_PREFIX

    attr_reader :connection, :channel

    def initialize(user: nil)
      @connection = ActionCable::Channel::ConnectionStub.new(current_user: user)
      # What the stub lacks and the server's worker pool needs to run a stream's handler:
      # the pool itself, and the logger a real connection has.
      logger = ActionCable::Connection::TaggedLoggerProxy.new(ActiveSupport::TaggedLogging.new(Logger.new(nil)), tags: [])
      @connection.define_singleton_method(:worker_pool) { ActionCable.server.worker_pool }
      @connection.define_singleton_method(:logger) { logger }
      @channel = GraphqlChannel.new(connection, { channel: 'GraphqlChannel' }.to_json, {})
      @channel.subscribe_to_channel
    end

    # Send an operation as the browser would; returns the immediate response.
    def execute(query, variables: {})
      channel.perform_action('action' => 'execute', 'query' => query, 'variables' => variables)
      await_event_loop
      messages.last
    end

    # The ids of the subscriptions this socket holds: the streams their updates are sent on.
    def subscription_ids
      channel.send(:streams).keys.filter_map { |stream| stream.delete_prefix(SUBSCRIPTION_STREAM) if stream.start_with?(SUBSCRIPTION_STREAM) }
    end

    # What the server transmitted, oldest first (the subscription confirmation excluded).
    def messages
      connection.transmissions.filter_map { |transmission| transmission['message'] }
    end

    # The `data` of the updates received so far.
    def updates
      messages.drop(1).filter_map { |message| message.dig('result', 'data') }
    end

    # Streams are subscribed to the pub/sub on ActionCable's event loop, which runs
    # its tasks in order: once a task posted now has run, the streams are listening.
    def await_event_loop
      done = Concurrent::Event.new
      ActionCable.server.event_loop.post { done.set }
      raise 'ActionCable\'s event loop did not answer' unless done.wait(5)
    end

    # The socket closes: the channel stops its streams and forgets its subscriptions.
    def close
      channel.unsubscribe_from_channel
    end
  end

  def live_client(user: nil)
    Client.new(user: user).tap { |client| (@live_clients ||= []) << client }
  end

  # Waits for ActionCable's threads: until the block is true, or the timeout is over.
  def wait_until(timeout: 5)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    sleep 0.01 until yield || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
    yield
  end

  # Gives ActionCable's threads time to deliver what should NOT arrive.
  def settle(seconds = 0.3)
    sleep seconds
  end

  def close_live_clients
    Array(@live_clients).each(&:close)
  end
end
