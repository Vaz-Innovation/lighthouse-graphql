require 'rails_helper'

# @defer over HTTP: the endpoint streams the deferred fragments as multipart/mixed parts to a
# client that accepts them (Lighthouse::GraphQL::Defer, GraphqlController's ActionController::Live).
RSpec.describe 'Deferring fields', type: :request do
  let(:accept) { { 'Accept' => 'multipart/mixed;incrementalSpec=v0.2,application/json' } }
  let(:query) do
    <<~GRAPHQL
      query { posts(first: 10) { data { title ... @defer(label: "details") { author { name } comments { data { body } } } } } }
    GRAPHQL
  end

  # The JSON of each part of a multipart/mixed body.
  def parts(body)
    body.split(/\r\n-{3,5}(?:\r\n|\z)/).filter_map do |part|
      json = part.split("\r\n\r\n", 2)[1]
      JSON.parse(json) if json.present?
    end
  end

  def stream(query, headers: accept)
    post '/graphql', params: { query: query }, headers: headers, as: :json
    parts(response.body)
  end

  before do
    create_list(:post, 3).each { |post| create(:comment, post: post) }
  end

  it 'reads the Accept header once a request' do
    allow(Lighthouse::GraphQL::Defer).to receive(:ranges).and_call_original

    stream(query)

    expect(Lighthouse::GraphQL::Defer).to have_received(:ranges).once
  end

  it 'answers with multipart/mixed parts that a proxy does not buffer' do
    stream(query)

    expect(response.headers['Content-Type']).to start_with('multipart/mixed; boundary="-"; incrementalSpec=v0.2')
    expect(response.headers['Cache-Control']).to include('no-cache')
    expect(response.headers['X-Accel-Buffering']).to eq('no')
  end

  it 'streams the first response without the deferred fields, and announces them' do
    initial = stream(query).first

    expect(initial['hasNext']).to be(true)
    expect(initial['data']['posts']['data'].first.keys).to eq(['title'])
    expect(initial['pending'].pluck('id')).to eq(%w[0 1 2])
    expect(initial['pending'].first).to include('path' => ['posts', 'data', 0], 'label' => 'details')
  end

  it 'streams the deferred fragments after it, in a part of their own' do
    payloads = stream(query)
    later = payloads.last

    expect(payloads.size).to eq(2)
    expect(later['hasNext']).to be(false)
    expect(later['completed']).to eq(%w[0 1 2].map { |id| { 'id' => id } })
    expect(later['incremental'].first['data']).to match('author' => { 'name' => be_a(String) },
                                                        'comments' => { 'data' => [{ 'body' => 'Nice post!' }] })
  end

  it 'costs the queries of the same query without @defer' do
    plain = query.sub(/\.\.\. @defer\(label: "details"\) \{/, '... {')
    whole = sql_queries { graphql(plain) }
    deferred = sql_queries { stream(query) }

    expect(deferred.size).to eq(whole.size)
  end

  it 'delivers the response whole to a client that does not accept multipart/mixed' do
    body = graphql(query)

    expect(response.headers['Content-Type']).to start_with('application/json')
    expect(body['data']['posts']['data'].first.keys).to eq(%w[title author comments])
    expect(body).not_to have_key('pending')
  end

  it 'delivers the response whole to a client that reads the older format' do
    payloads = stream(query, headers: { 'Accept' => 'multipart/mixed;deferSpec=20220824,application/json' })

    expect(response.headers['Content-Type']).to start_with('application/json')
    expect(payloads).to eq([])
  end

  it 'answers a request without a query as the JSON path does' do
    post '/graphql', params: { variables: {} }, headers: accept, as: :json
    streamed = [response.status, response.parsed_body]
    post '/graphql', params: { variables: {} }, as: :json

    expect(streamed).to eq([response.status, response.parsed_body])
    expect(streamed.last['errors']).to be_present
  end

  it 'answers an ordinary response when the query defers nothing' do
    stream('{ posts(first: 1) { data { title } } }')

    expect(response.headers['Content-Type']).to start_with('application/json')
    expect(response.parsed_body['data']['posts']['data'].size).to eq(1)
  end

  it 'reports a document that breaks the specification as an error response' do
    stream('{ posts { data { ... @defer(label: "a") { title } ... @defer(label: "a") { id } } } }')

    expect(response.headers['Content-Type']).to start_with('application/json')
    expect(response.parsed_body['errors'].first['message']).to include('label "a"')
  end

  it 'refuses a document that breaks the rules to a JSON client too, before anything runs' do
    body = graphql('{ posts(first: 1) { data { ... @defer(label: "a") { title } ... @defer(label: "a") { id } } } }')

    expect(body).not_to have_key('data')
    expect(error_messages(body)).to eq(['The label "a" is used by more than one @defer or @stream in the document.'])
  end

  it 'refuses @defer on a root mutation field, through a named fragment too, and runs no mutation' do
    query = 'mutation { ...M } fragment M on Mutation { ... @defer { createTag(name: "deferred") { name } } }'

    stream(query)
    expect(error_messages(response.parsed_body)).to eq(['The @defer directive cannot be used on a root mutation field.'])
    expect(error_messages(graphql(query))).to eq(['The @defer directive cannot be used on a root mutation field.'])
    expect(Tag.where(name: 'deferred')).to be_empty
  end

  # PHP Lighthouse's DeferDBTest#testDeferNestedListFields, over HTTP: a round of fragments is one
  # query, however many objects it runs on (PHP Lighthouse puts @defer on the fields).
  it 'costs one query a round for nested fragments under a list' do
    query = '{ posts(first: 10) { data { title ... @defer { author { name ... @defer { posts { title } } } } } } }'
    plain = query.gsub(' @defer', '')
    whole = sql_queries { graphql(plain) }
    payloads = nil
    deferred = sql_queries { payloads = stream(query) }

    expect(payloads.size).to eq(3)
    expect(payloads.last['incremental'].size).to eq(3)
    expect(deferred.size).to eq(whole.size)
  end

  it 'answers a @throttle past its limit in a deferred fragment with a field error, and ends the stream' do
    10.times { post '/graphql', params: { query: '{ searchPosts(term: "x") { title } }' }, env: { 'REMOTE_ADDR' => '10.9.0.1' }, as: :json }
    post '/graphql', params: { query: '{ posts(first: 1) { data { title } } ... @defer { searchPosts(term: "x") { title } } }' },
                     headers: accept, env: { 'REMOTE_ADDR' => '10.9.0.1' }, as: :json
    later = parts(response.body).last

    # searchPosts is non-null: its error leaves the fragment no data, and completes it.
    expect(later['completed'].first['errors'].pluck('message')).to eq(['Rate limit for Query.searchPosts exceeded. Try again later.'])
    expect(later['hasNext']).to be(false)
  end

  it "reports an error of the app's in a later round, and ends the stream, where it only drops a client that went away" do
    reported = []
    subscriber = Class.new { define_method(:report) { |error, **| reported << error } }.new
    Rails.error.subscribe(subscriber)
    allow_any_instance_of(Comment).to receive(:body).and_raise(EOFError, 'the app read past the end') # rubocop:disable RSpec/AnyInstance

    later = stream(query).last

    expect(later['completed'].first['errors']).to eq([{ 'message' => 'Internal server error' }])
    expect(later['hasNext']).to be(false)
    expect(reported.map(&:message)).to eq(['the app read past the end'])
  ensure
    Rails.error.unsubscribe(subscriber)
  end

  # A value of the app's that cannot be encoded as JSON.
  def unencodable(error)
    Object.new.tap { |value| value.define_singleton_method(:as_json) { |*| raise error } }
  end

  def reported_errors
    reported = []
    subscriber = Class.new { define_method(:report) { |error, **| reported << error } }.new
    Rails.error.subscribe(subscriber)
    yield
    reported
  ensure
    Rails.error.unsubscribe(subscriber)
  end

  it 'answers an error as the JSON path does when the first part cannot be encoded, nothing being written yet' do
    allow(Lighthouse::GraphQL::Incremental::Serializer).to receive(:initial).and_wrap_original do |original, *args, **options|
      original.call(*args, **options).merge('extensions' => { 'bad' => unencodable(RuntimeError.new('cannot encode')) })
    end

    reported = reported_errors do
      expect { stream(query) }.to raise_error(RuntimeError, 'cannot encode')
    end

    expect(reported.map(&:message)).to eq(['cannot encode'])
  end

  it 'reports an IOError of the app while encoding a later part, which is no client going away, and ends the stream' do
    allow(Lighthouse::GraphQL::Incremental::Serializer).to receive(:subsequent).and_wrap_original do |original, **payload|
      next original.call(**payload) if payload[:incremental].empty? # the last part a failure writes holds no value of the app's

      original.call(**payload).merge('extensions' => { 'bad' => unencodable(EOFError.new('the app read past the end')) })
    end

    payloads = nil
    reported = reported_errors { payloads = stream(query) }

    expect(reported.map(&:message)).to eq(['the app read past the end'])
    expect(payloads.last).to eq('completed' => %w[0 1 2].map { |id| { 'id' => id, 'errors' => [{ 'message' => 'Internal server error' }] } },
                                'hasNext' => false)
  end

  it 'ends the response quietly when the client goes away' do
    reported = []
    subscriber = Class.new { define_method(:report) { |error, **| reported << error } }.new
    Rails.error.subscribe(subscriber)
    writes = 0
    allow_any_instance_of(Lighthouse::GraphQL::Incremental::Multipart).to receive(:emit).and_wrap_original do |original, part| # rubocop:disable RSpec/AnyInstance
      raise ActionController::Live::ClientDisconnected, 'client disconnected' if (writes += 1) > 1

      original.call(part)
    end

    expect(stream(query).size).to eq(1)
    expect(reported).to eq([])
  ensure
    Rails.error.unsubscribe(subscriber)
  end

  it 'streams the items of a paginated list after the first ones' do
    initial, later = stream('{ posts(first: 10) { data @stream(initialCount: 1, label: "rest") { title } } }')

    expect(initial['data']['posts']['data'].size).to eq(1)
    expect(initial['pending']).to eq([{ 'id' => '0', 'path' => %w[posts data], 'label' => 'rest' }])
    expect(later['incremental'].first['items'].size).to eq(2)
    expect(later['completed']).to eq([{ 'id' => '0' }])
  end

  it 'closes the stream when the request is done, which is what ends the response for a real client' do
    stream(query)

    expect(controller.response.stream).to be_closed
  end

  it 'dispatches the request events once, around the whole stream' do
    events = []
    Lighthouse::Events.listen(Lighthouse::Events::StartRequest) { (events << :start) && nil }
    Lighthouse::Events.listen(Lighthouse::Events::EndRequest) { (events << :end) && nil }

    stream(query)

    expect(events).to eq(%i[start end])
  ensure
    Lighthouse::Events.reset!
  end
end
