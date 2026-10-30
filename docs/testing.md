# Testing

`Lighthouse::GraphQL::Testing` sends requests to the app's GraphQL endpoint from its tests, as PHP
Lighthouse's `MakesGraphQLRequests` does. Include it where Rails' integration session runs: an RSpec
request spec, or an `ActionDispatch::IntegrationTest`.

```ruby
# spec/rails_helper.rb
RSpec.configure do |config|
  config.include Lighthouse::GraphQL::Testing, type: :request
end

# test/test_helper.rb
class ActionDispatch::IntegrationTest
  include Lighthouse::GraphQL::Testing
end
```

Each request answers the response's parsed JSON body; `response` holds the response itself, as
after any request (its status, its headers). The requests go to `graphql_endpoint`, `/graphql`
unless a test overrides it.

## Queries and mutations

`graphql(query, variables = {}, extra_params: {}, headers: {})`, PHP Lighthouse's `graphQL`, posts
an operation as JSON:

```ruby
RSpec.describe 'Posts', type: :request do
  it 'lists the posts' do
    create(:post, title: 'Hello')

    body = graphql(<<~GRAPHQL, { first: 10 })
      query($first: Int!) { posts(first: $first) { data { title } } }
    GRAPHQL

    expect(body.dig('data', 'posts', 'data')).to eq([{ 'title' => 'Hello' }])
  end

  it 'signs the user in' do
    body = graphql('{ me { name } }', headers: { 'Authorization' => "Bearer #{user.api_token}" })

    expect(body.dig('data', 'me', 'name')).to eq(user.name)
  end
end
```

`extra_params` goes with the query: `operationName`, or `extensions` (a persisted query).
`post_graphql(data, headers: {})`, PHP Lighthouse's `postGraphQL`, posts `data` as it is: an
operation's Hash, or a batch's Array of them.

## Uploads

`multipart_graphql(operations, map, files, headers: {})`, PHP Lighthouse's `multipartGraphQL`,
sends a [multipart request](uploads.md): the operations, the map from each file's key to the
variables it fills, and the files by key.

```ruby
file = Rack::Test::UploadedFile.new(file_fixture('avatar.png'), 'image/png')

body = multipart_graphql(
  { query: 'mutation($file: Upload!) { uploadAvatar(file: $file) { url } }', variables: { file: nil } },
  { '0' => ['variables.file'] },
  { '0' => file }
)
```

## Introspection

`introspect` answers the response to graphql-ruby's introspection query; `introspect_type(name)`
and `introspect_directive(name)` the introspection of one type or directive, or nil when the
schema has none.

```ruby
expect(introspect_type('Post')['fields'].pluck('name')).to include('title')
expect(introspect_directive('defer')).to be_nil   # without Lighthouse::GraphQL::Defer
```

## Deferred fields

`stream_graphql(query, variables = {}, extra_params: {}, headers: {})`, PHP Lighthouse's
`streamGraphQL`, posts a query with `@defer` or `@stream`, as a client that reads `multipart/mixed`
does, and answers each payload of the [streamed response](defer.md), in order: the first, then one
per round.

```ruby
it 'defers the author' do
  initial, later = stream_graphql('{ posts(first: 1) { data { title ... @defer { author { name } } } } }')

  expect(initial['data']['posts']['data']).to eq([{ 'title' => 'Hello' }])
  expect(later['incremental'].first['data']).to eq('author' => { 'name' => 'Ana' })
  expect(later['hasNext']).to be(false)
end
```

It sends `Accept: multipart/mixed` unless the headers say otherwise; Apollo's older format is
`headers: { 'Accept' => 'multipart/mixed;deferSpec=20220824' }`. A response that comes whole (the
query deferred nothing, or the schema does not use `Lighthouse::GraphQL::Defer`) raises
`Lighthouse::GraphQL::Testing::NotStreamed`.
