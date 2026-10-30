# frozen_string_literal: true

require 'base64'

# Relay's global object identification: @globalId and @node.
class RelaySpecCountries
  COUNTRIES = { 'DE' => { id: 'DE', name: 'Germany' }, 'MY' => { id: 'MY', name: 'Malaysia' } }.freeze

  def self.by_code(id, _context) = COUNTRIES[id]
end

RSpec.describe 'Relay global ids (@globalId, @node)' do
  let(:sdl) do
    <<~GRAPHQL
      type Query {
        posts: [Post!]! @all
        stories: [RelayStory!]! @all(model: "Post")
        post(id: ID! @globalId(decode: ID) @eq): Post @find
        decoded(id: ID! @globalId): [String] @field(resolver: "RelaySpecEcho")
        typeOf(id: ID! @globalId(decode: TYPE)): String @field(resolver: "RelaySpecEcho")
        many(ids: [ID!]! @globalId(decode: ID)): [String] @field(resolver: "RelaySpecEchoIds")
        nested(input: RelaySpecInput!): String @field(resolver: "RelaySpecEchoInput")
      }

      input RelaySpecInput { postId: ID! @globalId(decode: ID) note: String }

      type Post @node { id: ID! @globalId title: String }
      type RelayStory @node @model(class: "Post") { id: ID! @globalId title: String }
      type Country @node(resolver: "RelaySpecCountries@by_code") { id: ID! @globalId name: String }
      type Plain { id: ID! }
    GRAPHQL
  end

  let(:schema) { build_schema(sdl, dataloader: true) }
  let(:post_record) { Post.create!(title: 'Hello') }

  before do
    stub_const('RelaySpecEcho', ->(_obj, args, _ctx) { args[:id] })
    stub_const('RelaySpecEchoIds', ->(_obj, args, _ctx) { args[:ids] })
    stub_const('RelaySpecEchoInput', ->(_obj, args, _ctx) { "#{args[:input][:post_id]} #{args[:input][:note]}" })
  end

  def gid(type, id) = Base64.strict_encode64("#{type}:#{id}")

  def run(query) = schema.execute(query).to_h

  it 'encodes a field with the type name: base64 of "Type:id"' do
    post_record

    expect(run('{ posts { id } }').dig('data', 'posts')).to eq([{ 'id' => gid('Post', post_record.id) }])
  end

  it 'adds the Node interface, implements it on every @node type, and adds Query.node' do
    definition = schema.to_definition

    expect(definition).to include('interface Node', 'type Post implements Node', 'type Country implements Node',
                                  'node(id: ID!): Node')
    expect(schema.query.fields['node'].type.unwrap.graphql_name).to eq('Node')
  end

  it 'finds a record through Query.node by the model named after its type, or its @model' do
    result = run(%({ a: node(id: "#{gid('Post', post_record.id)}") { __typename id ... on Post { title } }
                     b: node(id: "#{gid('RelayStory', post_record.id)}") { __typename ... on RelayStory { title } } }))

    expect(result['data']).to eq('a' => { '__typename' => 'Post', 'id' => gid('Post', post_record.id), 'title' => 'Hello' },
                                 'b' => { '__typename' => 'RelayStory', 'title' => 'Hello' })
  end

  it "finds an object through @node's resolver, which may return a Hash" do
    result = run(%({ node(id: "#{gid('Country', 'MY')}") { __typename id ... on Country { name } } }))

    expect(result.dig('data', 'node')).to eq('__typename' => 'Country', 'id' => gid('Country', 'MY'), 'name' => 'Malaysia')
  end

  it 'answers null for an id with no record' do
    expect(run(%({ node(id: "#{gid('Post', 0)}") { id } }))).to eq('data' => { 'node' => nil })
  end

  it 'refuses an id of a type without @node, or one that is no global id' do
    expect(run(%({ node(id: "#{gid('Plain', 1)}") { id } }))['errors'].pluck('message'))
      .to eq(['[Plain] is not a type that can be resolved by node.'])
    expect(run('{ node(id: "nope") { id } }')['errors'].pluck('message')).to eq(['"nope" is not a valid global id.'])
  end

  it 'decodes an argument into [type, id], the type or the id, lists and input fields included' do
    result = run(%({ decoded(id: "#{gid('Post', 7)}") typeOf(id: "#{gid('Post', 7)}")
                     many(ids: ["#{gid('Post', 1)}", "#{gid('Post', 2)}"])
                     nested(input: { postId: "#{gid('Post', 3)}", note: "kept" }) }))

    expect(result['data']).to eq('decoded' => %w[Post 7], 'typeOf' => 'Post', 'many' => %w[1 2], 'nested' => '3 kept')
  end

  it 'decodes before the field resolves, so @eq and @find get the id' do
    expect(run(%({ post(id: "#{gid('Post', post_record.id)}") { title } }))).to eq('data' => { 'post' => { 'title' => 'Hello' } })
  end

  it 'encodes and decodes through Config.global_id' do
    codec = Class.new do
      def encode(type, id) = "#{type}/#{id}"
      def decode(gid) = gid.split('/')
    end
    Lighthouse.configure { |c| c.global_id = codec.new }
    post_record

    expect(run('{ posts { id } }').dig('data', 'posts', 0, 'id')).to eq("Post/#{post_record.id}")
    expect(run(%({ node(id: "Post/#{post_record.id}") { id } })).dig('data', 'node', 'id')).to eq("Post/#{post_record.id}")
  end

  it 'keeps a Query.node and a Node interface the SDL declares itself' do
    own = build_schema(<<~GRAPHQL)
      "Mine."
      interface Node { id: ID! }
      type Query { "Also mine." node(id: ID! @globalId): Node @field(resolver: "Lighthouse::GraphQL::NodeRegistry@resolve") }
      type Post @node { id: ID! @globalId }
    GRAPHQL

    expect(own.query.fields['node'].description).to eq('Also mine.')
    expect(own.get_type('Node').description).to eq('Mine.')
  end
end
