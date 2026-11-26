# frozen_string_literal: true

require 'puma'
require 'timeout'

# Apollo Router's callback endpoint, played here: it records every message the
# subgraph sends, and answers as the router does (204 for a check).
class CallbackEndpoint
  attr_reader :messages, :port

  def initialize
    @messages = Queue.new
    @server = Puma::Server.new(method(:call), nil, min_threads: 1, max_threads: 4, log_writer: Puma::LogWriter.null)
    @port = @server.add_tcp_listener('127.0.0.1', 0).addr[1]
    @server.run
  end

  def call(env)
    message = JSON.parse(env['rack.input'].read)
    @messages << message.merge('subscription-protocol' => env['HTTP_SUBSCRIPTION_PROTOCOL'])
    [message['action'] == 'check' ? 204 : 200, { 'subscription-protocol' => 'callback/1.0' }, []]
  end

  def url(id) = "http://127.0.0.1:#{port}/callback/#{id}"

  # The next message, waiting for it a while.
  def next_message(timeout: 10)
    Timeout.timeout(timeout) { @messages.pop }
  end

  def stop = @server.stop(true)
end
