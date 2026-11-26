# frozen_string_literal: true

# Federated subscriptions: the blog subgraph delivers its Subscription fields to
# Apollo Router through the router's HTTP callback protocol
# (Lighthouse::GraphQL::Federation::CallbackSubscriptions).
RSpec.describe 'Federated subscriptions' do
  let(:ada) { sign_up(name: 'Ada Lovelace') }

  describe 'the callback protocol, the router played by the spec' do
    let(:endpoint) { CallbackEndpoint.new }

    after { endpoint.stop }

    # What the router sends the subgraph to subscribe.
    def subscribe(query, id:, variables: {}, token: nil, heartbeat: 0)
      extensions = { subscription: { callbackUrl: endpoint.url(id), subscriptionId: id, verifier: "verifier-#{id}", heartbeatIntervalMs: heartbeat } }
      subgraph('blog', token: token).execute(query, variables: variables, extensions: extensions,
                                                    headers: { 'Accept' => 'application/json;callbackSpec=1.0' })
    end

    it 'checks the callback first, answers { data: null }, then sends each update as a next message' do
      id = SecureRandom.uuid
      post_id = write_post(ada, title: 'Draft', published: false)

      expect(subscribe('subscription { postPublished { title } }', id: id)).to eq('data' => nil)
      expect(endpoint.next_message).to eq('kind' => 'subscription', 'action' => 'check', 'id' => id, 'verifier' => "verifier-#{id}",
                                          'subscription-protocol' => 'callback/1.0')

      router(token: ada[:token]).execute('mutation($id: ID!) { publishPost(id: $id) { id } }', variables: { id: post_id })

      expect(endpoint.next_message).to include('action' => 'next', 'id' => id, 'verifier' => "verifier-#{id}",
                                               'payload' => { 'data' => { 'postPublished' => { 'title' => 'Draft' } } })
    end

    it 'filters the updates by the arguments of each subscriber, as the subscription class says' do
      grace = sign_up(name: 'Grace Hopper')
      mine = SecureRandom.uuid
      subscribe('subscription($author: ID) { postPublished(authorId: $author) { title } }', id: mine, variables: { author: ada[:id] })
      endpoint.next_message

      write_post(grace, title: 'Not for me', published: false).then do |id|
        router(token: grace[:token]).execute('mutation($id: ID!) { publishPost(id: $id) { id } }', variables: { id: id })
      end
      write_post(ada, title: 'For me', published: false).then do |id|
        router(token: ada[:token]).execute('mutation($id: ID!) { publishPost(id: $id) { id } }', variables: { id: id })
      end

      expect(endpoint.next_message.dig('payload', 'data', 'postPublished', 'title')).to eq('For me')
    end

    it 'refuses a subscriber its class does not authorize, with the error the router passes on' do
      expect(messages(subscribe('subscription { postCreated { title } }', id: SecureRandom.uuid))).to eq(['Sign in to subscribe to new posts.'])
    end

    it 'sends the check heartbeats the router asks for' do
      id = SecureRandom.uuid
      subscribe('subscription { commentAdded { body } }', id: id, heartbeat: 500)

      checks = Array.new(3) { endpoint.next_message(timeout: 5) }

      expect(checks.map { |message| message['action'] }).to eq(%w[check check check])
    end

    it 'refuses a subscription that came through neither the router, SSE nor a channel' do
      result = subgraph('blog').execute('subscription { postPublished { title } }')

      expect(messages(result).first).to include('subscribe through one of them')
    end
  end

  # Clients subscribe through the router (multipart HTTP here), which asks the blog
  # with a callback, and resolves the accounts fields of every update.
  describe 'through the router', if: Stack.licensed? do
    it 'delivers a broadcast to a client of the router, with the fields of both subgraphs' do
      chunks = Queue.new
      uri = URI(Stack.router_url)
      reader = Thread.new do
        request = Net::HTTP::Post.new('/', 'Content-Type' => 'application/json',
                                           'Accept' => 'multipart/mixed;subscriptionSpec="1.0", application/json')
        request.body = JSON.generate(query: 'subscription { postPublished { title author { name } } }')
        Net::HTTP.start(uri.host, uri.port, read_timeout: 30) do |http|
          http.request(request) { |response| response.read_body { |chunk| chunks << chunk } }
        end
      end
      sleep 1
      id = write_post(ada, title: 'Live', published: false)
      router(token: ada[:token]).execute('mutation($id: ID!) { publishPost(id: $id) { id } }', variables: { id: id })

      payload = Timeout.timeout(15) do
        loop do
          json = chunks.pop[/\{.*\}/m]
          parsed = json && JSON.parse(json)
          break parsed if parsed&.dig('payload', 'data')
        end
      end

      expect(payload['payload']['data']).to eq('postPublished' => { 'title' => 'Live', 'author' => { 'name' => 'Ada Lovelace' } })
    ensure
      reader&.kill
    end
  end
end
