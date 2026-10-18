# frozen_string_literal: true

# A schema on the code-first types graphql-ruby's install writes: the SDL's
# root types built on Types::QueryType / MutationType, its Node interface
# Types::NodeType, its global ids the schema's id_from_object / object_from_id.
RSpec.describe 'Code-first root types and Node (RootTypes)' do
  # graphql-ruby's Types::NodeType, handed to Lighthouse as lighthouse:install does.
  let(:node_type) do
    stub_const('Types::NodeType', Module.new do
      include GraphQL::Schema::Interface
      include GraphQL::Types::Relay::NodeBehaviors
      include Lighthouse::GraphQL::Type

      graphql_name 'Node'
    end)
  end

  # graphql-ruby's install, with its Relay fields.
  let(:query_type) do
    node = node_type
    Class.new(GraphQL::Schema::Object) do
      graphql_name 'Query'

      field :node, node, null: true do
        argument :id, GraphQL::Types::ID
      end

      def node(id:) = context.schema.object_from_id(id, context)

      field :greeting, String, null: false

      def greeting = 'hi from Ruby'
    end
  end

  # What `graphql:mutation` adds to Types::MutationType.
  let(:mutation_type) do
    Class.new(GraphQL::Schema::Object) do
      graphql_name 'Mutation'

      field :touch, String, null: false

      def touch = 'touched'
    end
  end

  let(:sdl) do
    <<~GRAPHQL
      type Query {
        posts: [Post!]! @all
        post(id: ID! @globalId(decode: ID) @eq): Post @find
      }

      type Post @node {
        id: ID! @globalId
        title: String
      }
    GRAPHQL
  end

  # The app's schema class, as graphql-ruby's install writes it with Relay.
  let(:schema) do
    parent = build_schema(sdl, base_types: { query_type: query_type, mutation_type: mutation_type, node: node_type }, dataloader: true)
    Class.new(parent) do
      def self.id_from_object(object, type, _context) = "#{type.graphql_name}:#{object.id}"
      def self.object_from_id(global_id, _context) = Post.find_by(id: global_id.to_s.split(':').last)
    end
  end

  let!(:post) { Post.create!(title: 'Hello') }

  def run(query) = schema.execute(query).to_h

  it "answers the code-first base's fields, as graphql-ruby resolves them, beside the SDL's" do
    expect(run('{ greeting posts { title } }')).to eq('data' => { 'greeting' => 'hi from Ruby', 'posts' => [{ 'title' => 'Hello' }] })
  end

  it 'makes a root type class the SDL has no type for the root itself' do
    expect(run('mutation { touch }')).to eq('data' => { 'touch' => 'touched' })
  end

  it "shares one Node and one kind of global id with graphql-ruby's Relay" do
    result = run(%({ posts { id } node(id: "Post:#{post.id}") { id ... on Post { title } } post(id: "Post:#{post.id}") { title } }))

    expect(result).to eq('data' => { 'posts' => [{ 'id' => "Post:#{post.id}" }], 'node' => { 'id' => "Post:#{post.id}", 'title' => 'Hello' },
                                     'post' => { 'title' => 'Hello' } })
    expect(schema.types['Node']).to equal(node_type)
    expect(schema.query.fields['node'].owner).to equal(query_type)
  end

  it 'refuses a root type that is not an object type class' do
    expect { build_schema(sdl, base_types: { query_type: node_type }) }
      .to raise_error(Lighthouse::DefinitionError, /base_types\[:query_type\] must be a subclass of GraphQL::Schema::Object/)
  end

  describe 'the rest of what graphql-ruby writes' do
    it "resolves an SDL mutation by convention to a RelayClassicMutation, graphql-ruby's base, with its arguments as keywords" do
      stub_const('Mutations::RootSpecPublish', Class.new(GraphQL::Schema::RelayClassicMutation) { def resolve(title:) = "published #{title}" })
      schema = build_schema('type Query { a: Int } type Mutation { rootSpecPublish(title: String!): String }')

      expect(schema.execute('mutation { rootSpecPublish(title: "Hi") }').to_h).to eq('data' => { 'rootSpecPublish' => 'published Hi' })
    end

    it 'delivers the Subscription fields through a backend the app schema class uses' do
      parent = build_schema('type Query { a: Int } type Subscription { pinged: String }')
      backend = Class.new(GraphQL::Subscriptions) { def write_subscription(*) = nil }
      app_schema = Class.new(parent) { use backend }

      expect(app_schema.subscription.fields['pinged'].extensions).to include(an_instance_of(GraphQL::Subscriptions::DefaultSubscriptionResolveExtension))
    end
  end

  it "resolves a root field with the root type class's method when it is Lighthouse's, else by convention" do
    stub_const('Resolvers::RootSpecByClass', Class.new(GraphQL::Schema::Resolver) { def resolve = 'by class' })
    root = Class.new(GraphQL::Schema::Object) do
      include Lighthouse::GraphQL::Type

      graphql_name 'Query'

      def root_spec_by_method = "by method, #{context[:who]}"
    end
    schema = build_schema('type Query { rootSpecByMethod: String rootSpecByClass: String }', base_types: { query_type: root })

    expect(schema.execute('{ rootSpecByMethod rootSpecByClass }', context: { who: 'Ada' }).to_h)
      .to eq('data' => { 'rootSpecByMethod' => 'by method, Ada', 'rootSpecByClass' => 'by class' })
  end
end
