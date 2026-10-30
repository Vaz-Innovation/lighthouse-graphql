require 'rails_helper'
require 'puma'
require 'socket'

# A streamed response through a real server (Puma, on a port the OS picks), read off the socket
# as a client reads it: the first part arrives before the deferred fragments run. The round that
# runs them waits until the client has read the first part, so a response buffered anywhere
# (Rails, a middleware, the server) never arrives, and the spec times out.
RSpec.describe 'Deferring fields through a server', type: :request do
  let(:release) { Queue.new }
  let(:server) { Puma::Server.new(Rails.application, nil, min_threads: 1, max_threads: 2) }
  let(:port) { server.add_tcp_listener('127.0.0.1', 0).addr[1] }
  # The last chunk of a chunked response.
  let(:end_of_body) { /\r\n0\r\n\r\n\z/ }

  before do
    gate = release
    allow_any_instance_of(Lighthouse::GraphQL::Incremental::Plan).to receive(:units).and_wrap_original do |original, *args| # rubocop:disable RSpec/AnyInstance
      gate.pop
      original.call(*args)
    end
    port
    server.run
  end

  after { server.stop(true) }

  # Sends a query that defers, as a client that reads multipart/mixed, and answers the socket.
  def request(accept)
    body = { query: '{ __typename ... @defer(label: "later") { publishedPostCount } }' }.to_json
    socket = TCPSocket.new('127.0.0.1', port)
    socket.write("POST /graphql HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\nAccept: #{accept}\r\n" \
                 "Content-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}")
    socket
  end

  # What the socket has sent once `pattern` shows up in it.
  def read_until(socket, pattern, read = +'')
    Timeout.timeout(10) { read << socket.readpartial(4096) until read.match?(pattern) }
    read
  rescue EOFError
    raise "the server closed the connection after: #{read.inspect}"
  end

  # The body of a chunked response, its chunks joined.
  def dechunk(response)
    rest = response.split("\r\n\r\n", 2).last
    body = +''
    until (size = rest[/\A\h+/].to_i(16)).zero?
      start = rest.index("\r\n") + 2
      body << rest[start, size]
      rest = rest[(start + size + 2)..]
    end
    body
  end

  it 'sends the first part before the deferred fragments run, then the rest, chunked' do
    socket = request('multipart/mixed')
    first = read_until(socket, /"hasNext":true\}\r\n---/)

    expect(first).to start_with('HTTP/1.1 200')
    expect(first).to match(%r{^content-type: multipart/mixed; boundary="-"\r$}i)
    expect(first).to match(/^transfer-encoding: chunked\r$/i)
    expect(first).not_to include('"incremental"')

    release << true
    body = dechunk(read_until(socket, end_of_body, first))
    payloads = Lighthouse::GraphQL::Incremental::Multipart.parse(body)

    expect(body).to end_with("\r\n-----\r\n")
    expect(payloads.first).to eq('data' => { '__typename' => 'Query' }, 'pending' => [{ 'id' => '0', 'path' => [], 'label' => 'later' }],
                                 'hasNext' => true)
    expect(payloads.last).to eq('incremental' => [{ 'id' => '0', 'data' => { 'publishedPostCount' => 0 } }],
                                'completed' => [{ 'id' => '0' }], 'hasNext' => false)
  ensure
    socket&.close
  end

  it "sends Apollo's older format the same way" do
    socket = request('multipart/mixed;deferSpec=20220824,application/json')
    first = read_until(socket, /"hasNext":true\}\r\n---/)
    release << true
    payloads = Lighthouse::GraphQL::Incremental::Multipart.parse(dechunk(read_until(socket, end_of_body, first)))

    expect(first).to match(%r{^content-type: multipart/mixed; boundary="-"; deferSpec=20220824\r$}i)
    expect(payloads).to eq([{ 'data' => { '__typename' => 'Query' }, 'hasNext' => true },
                            { 'incremental' => [{ 'data' => { 'publishedPostCount' => 0 }, 'path' => [], 'label' => 'later' }], 'hasNext' => false }])
  ensure
    socket&.close
  end
end
