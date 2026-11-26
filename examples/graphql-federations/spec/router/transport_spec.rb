# frozen_string_literal: true

require 'digest'

# How requests travel: automatic persisted queries (the router's, and the router
# sending Lighthouse's to the subgraphs), @defer across subgraphs, and batches.
RSpec.describe 'Transport through Apollo Router' do
  let(:ada) { sign_up(name: 'Ada Lovelace') }

  # What a subgraph logged (its log/test.log) while the block ran.
  def logged(name)
    path = File.join(Stack::ROOT, name, 'log/test.log')
    offset = File.size?(path).to_i
    yield
    File.read(path).byteslice(offset..)
  end

  it "runs a client's automatic persisted query, and sends the subgraphs Lighthouse's" do
    query = "query Apq#{SecureRandom.hex(3)} { userCount posts(first: 1) { paginatorInfo { total } } }"
    extensions = { persistedQuery: { version: 1, sha256Hash: Digest::SHA256.hexdigest(query) } }

    unknown = router.post_body({ extensions: extensions })
    registered = by_hash = nil
    blog = nil
    accounts = logged('accounts') do
      blog = logged('blog') do
        registered = router.post_body({ query: query, extensions: extensions })
        by_hash = router.post_body({ extensions: extensions })
      end
    end

    expect(JSON.parse(unknown.body)['errors'].first['extensions']['code']).to eq('PERSISTED_QUERY_NOT_FOUND')
    expect(JSON.parse(registered.body)['data'].keys).to eq(%w[userCount posts])
    expect(JSON.parse(by_hash.body)).to eq(JSON.parse(registered.body))
    # The router sent each subgraph a hash (persistedQuery), which Lighthouse resolved.
    expect([accounts, blog]).to all(include('persistedQuery'))
  end

  it '@defer: the router streams the deferred fields, fetched from the other subgraph, after the rest' do
    id = write_post(ada, title: 'Deferred')

    response = router(headers: { 'Accept' => 'multipart/mixed;deferSpec=20220824, application/json' })
               .post_body({ query: 'query($id: ID!) { post(id: $id) { title ... @defer { author { name } } } }', variables: { id: id } })
    parts = response.body.split(/^--graphql.*$/).filter_map { |part| part[/\{.*\}/m] }.map { |json| JSON.parse(json) }

    expect(response['content-type']).to start_with('multipart/mixed')
    expect(parts.first).to include('data' => { 'post' => { 'title' => 'Deferred' } }, 'hasNext' => true)
    expect(parts.flat_map { |part| part['incremental'] || [] }.map { |increment| increment['data'] })
      .to include('author' => { 'name' => 'Ada Lovelace' })
  end

  it 'refuses what the API does not have, as GraphQL validation errors' do
    result = router.execute('{ user(id: 1) { nickname } }')

    expect(result['errors'].first['extensions']['code']).to eq('GRAPHQL_VALIDATION_FAILED')
  end

  context 'with a router connected to GraphOS', if: Stack.licensed? do
    it "runs a client's batch, batching its fetches to each subgraph, which Lighthouse runs as a multiplex" do
      response = router.post_body([{ query: '{ userCount }' }, { query: '{ posts(first: 1) { paginatorInfo { total } } }' }])

      expect(JSON.parse(response.body).map { |result| result['data'].keys }).to eq([['userCount'], ['posts']])
    end
  end
end
