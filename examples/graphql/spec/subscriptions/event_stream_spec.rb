require 'rails_helper'

# GraphQL over Server-Sent Events (Lighthouse::GraphQL::EventStream): a request whose
# Accept names text/event-stream is answered in graphql-sse's distinct connections
# mode. A subscription stays open, on the same ActionCableSubscriptions backend as
# GraphqlChannel's sockets: a mutation's broadcast reaches it through Action Cable's
# pub/sub, as it reaches a WebSocket.
RSpec.describe 'Subscriptions over Server-Sent Events', :live_cable, type: :request do
  let(:author) { create(:user) }
  let(:reader) { create(:user) }
  let(:sse) { { 'Accept' => 'text/event-stream' } }
  let(:streams) { [] }

  def results(body) = Lighthouse::GraphQL::EventStream.parse(body)

  # The request as a server runs it: the app answers, then the body is written as it
  # comes, here into a queue, on a thread of its own (the server's, held while it is open).
  def open_stream(query, as: nil)
    headers = { 'HTTP_ACCEPT' => 'text/event-stream', 'HTTP_AUTHORIZATION' => auth_headers(as)['Authorization'] }
    env = Rack::MockRequest.env_for("/graphql?#{{ query: query }.to_query}", headers)
    status, headers, body = Rails.application.call(env)
    chunks = Queue.new
    thread = Thread.new do
      body.each { |chunk| chunks << chunk }
    ensure
      body.close if body.respond_to?(:close)
      chunks << :closed
    end
    streams << thread
    { status: status, headers: headers, chunks: chunks }
  end

  # What the stream wrote until it ended, or until `timeout`.
  def read_until(stream, timeout: 5)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    written = +''
    loop do
      chunk = stream[:chunks].pop(timeout: [deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC), 0].max)
      break if chunk.nil? || chunk == :closed

      written << chunk
      break if yield(written)
    end
    written
  end

  def subscription_ids = AppSchema.subscriptions.instance_variable_get(:@subscriptions).keys

  after do
    subscription_ids.each { |id| AppSchema.subscriptions.delete_subscription(id) }
    streams.each { |thread| thread.join(5) }
  end

  it 'answers a query with one next event and complete' do
    post_record = create(:post, title: 'Hello', published: true, author: author)

    post '/graphql', params: { query: "{ post(id: #{post_record.id}) { title } }" }, headers: sse, as: :json

    expect(response.media_type).to eq('text/event-stream')
    expect(response.headers['Cache-Control']).to eq('no-store')
    expect(results(response.body)).to eq([{ 'data' => { 'post' => { 'title' => 'Hello' } } }])
    expect(response.body).to end_with(Lighthouse::GraphQL::EventStream::COMPLETE)
  end

  it 'answers a GET as well, and an invalid operation with its errors' do
    get '/graphql', params: { query: '{ nothing }' }, headers: sse

    expect(results(response.body).first['errors'].pluck('message')).to include(/nothing/)
    expect(response.body).to end_with(Lighthouse::GraphQL::EventStream::COMPLETE)
  end

  it 'streams the updates of a subscription, with a socket subscribed on the same backend' do
    stream = open_stream('subscription { postCreated { title } }', as: reader)
    socket = live_client(user: reader)
    socket.execute('subscription { postCreated { title } }')
    socket.await_event_loop
    expect(stream[:headers]['content-type']).to start_with('text/event-stream')

    graphql('mutation { createPost(input: { title: "Streamed", published: true }) { id } }', as: author)

    written = read_until(stream) { |body| body.include?('event: next') }
    expect(results(written)).to eq([{ 'data' => { 'postCreated' => { 'title' => 'Streamed' } } }])
    expect(wait_until { socket.updates.any? }).to be(true)
    expect(socket.updates).to eq([{ 'postCreated' => { 'title' => 'Streamed' } }])

    # Ended on the server: the stream completes, and its subscription is gone.
    sse_id = (subscription_ids - socket.subscription_ids).first
    AppSchema.subscriptions.delete_subscription(sse_id)
    expect(read_until(stream) { |body| body.end_with?(Lighthouse::GraphQL::EventStream::COMPLETE) })
      .to eq(Lighthouse::GraphQL::EventStream::COMPLETE)
    expect(wait_until { subscription_ids == socket.subscription_ids }).to be(true)
  end

  it "runs each update in the subscriber's context: another author's draft does not reach a reader" do
    stream = open_stream('subscription { postCreated { title } }', as: reader)
    wait_until { subscription_ids.any? }

    graphql('mutation { createPost(input: { title: "Draft" }) { id } }', as: author)
    graphql('mutation { createPost(input: { title: "Public", published: true }) { id } }', as: author)

    written = read_until(stream) { |body| body.include?('event: next') }
    expect(results(written)).to eq([{ 'data' => { 'postCreated' => { 'title' => 'Public' } } }])
  end
end
