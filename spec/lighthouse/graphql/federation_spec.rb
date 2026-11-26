# frozen_string_literal: true

RSpec.describe Lighthouse::GraphQL::Federation do
  include_context 'with PHP Lighthouse models'

  let(:entities_query) do
    <<~GRAPHQL
      query($representations: [_Any!]!) {
        _entities(representations: $representations) {
          __typename
          ... on User { id name email }
          ... on Post { id title }
        }
      }
    GRAPHQL
  end

  def entities(representations, query = entities_query)
    graphql(query, { 'representations' => representations })
  end

  describe 'the subgraph SDL (_service { sdl })' do
    let(:schema) do
      build_subgraph(<<~GRAPHQL, imports: %w[@key @shareable @external @requires @override @inaccessible @tag @interfaceObject @cost])
        type Query {
          users(role: Role @tag(name: "filter") @eq): [User!]! @all
          posts: [Post!]! @paginate
          feed: [Post!]! @paginate(type: CONNECTION)
        }

        type User @key(fields: "id") @key(fields: "email") @tag(name: "public") {
          id: ID!
          name: String! @shareable
          email: String @inaccessible
          role: Role
          shout: String @requires(fields: "name") @override(from: "accounts") @cost(weight: 2)
        }

        type Post @key(fields: "id", resolvable: false) {
          id: ID!
          title: String @external
        }

        type Media @key(fields: "id") @interfaceObject {
          id: ID!
        }

        enum Role {
          ADMIN @tag(name: "staff")
          MEMBER @inaccessible
        }

        input UserInput {
          name: String @tag(name: "input")
        }

        type Mutation {
          rename(input: UserInput): User
        }
      GRAPHQL
    end

    let(:sdl) { schema.execute('{ _service { sdl } }').to_h.dig('data', '_service', 'sdl') }

    it 'keeps the link' do
      expect(sdl).to start_with("extend schema\n  @link(url: \"https://specs.apollo.dev/federation/v2.9\"")
    end

    it 'keeps every federation directive on types and fields' do
      expect(sdl).to include('type User @key(fields: "id") @key(fields: "email") @tag(name: "public")', 'name: String! @shareable',
                             'email: String @inaccessible', 'shout: String @requires(fields: "name") @override(from: "accounts") @cost(weight: 2)',
                             'type Post @key(fields: "id", resolvable: false)', 'title: String @external',
                             'type Media @key(fields: "id") @interfaceObject')
    end

    it 'keeps them on enum values, arguments and input fields' do
      expect(sdl).to include('ADMIN @tag(name: "staff")', 'MEMBER @inaccessible', 'role: Role @tag(name: "filter")',
                             'name: String @tag(name: "input")')
    end

    it "leaves out Lighthouse's directives and what the spec adds or declares" do
      expect(sdl).not_to match(/@all|@eq|@paginate|directive @key|directive @link|_entities|_service|_Any|_Entity|_Service|link__/)
    end

    it 'makes the pagination types every paginating subgraph generates @shareable' do
      %w[PaginatorInfo PostPaginator PageInfo PostConnection PostEdge].each do |name|
        expect(sdl).to include("type #{name} @shareable")
      end
    end

    it 'is what federation_sdl and the federation format print' do
      expect(schema.federation_sdl).to eq(sdl)
      expect(Lighthouse::GraphQL::SchemaPrinter.print(schema, format: 'federation')).to eq(sdl)
    end

    it 'drops a Query with only the spec fields' do
      schema = build_subgraph('type User @key(fields: "id") { id: ID! }')

      expect(schema.federation_sdl).not_to include('type Query')
      expect(schema.query.fields.keys).to contain_exactly('_entities', '_service')
    end
  end

  describe 'the spec directives a subgraph does not import' do
    let(:schema) do
      build_subgraph(<<~GRAPHQL, imports: [])
        type Query { users: [User!]! @all }
        type User @federation__key(fields: "id") @federation__shareable { id: ID! name: String }
      GRAPHQL
    end

    it 'go by the namespaced names, and still make entities' do
      expect(schema.federation_sdl).to include('type User @federation__key(fields: "id") @federation__shareable')
      expect(schema.get_type('_Entity').possible_types.map(&:graphql_name)).to eq(['User'])
    end

    it "take the link's `as:` and the imports' renames" do
      schema = build_schema(<<~GRAPHQL)
        extend schema @link(url: "https://specs.apollo.dev/federation/v2.3", as: "fed", import: [{ name: "@key", as: "@id" }])
        type Query { users: [User!]! @all }
        type User @id(fields: "id") @fed__shareable { id: ID! }
      GRAPHQL

      expect(schema.get_type('_Entity').possible_types.map(&:graphql_name)).to eq(['User'])
    end
  end

  describe 'Federation 1 (federation: true, no link)' do
    let(:schema) do
      build_schema(<<~GRAPHQL, federation: true)
        type Query { users: [User!]! @paginate }
        type User @key(fields: "id") { id: ID! name: String @external }
      GRAPHQL
    end

    it 'prints the directives as written, with no link and no @shareable' do
      expect(schema.federation_sdl).to include('type User @key(fields: "id")', 'name: String @external')
      expect(schema.federation_sdl).not_to include('@link', '@shareable')
    end
  end

  describe 'a schema that is no subgraph' do
    it 'has none of it' do
      schema = build_schema('type Query { users: [User!]! @all } type User { id: ID! }')

      expect(schema.query.fields.keys).to eq(['users'])
      expect(schema).not_to respond_to(:federation_sdl)
    end

    it 'is a subgraph without entities when it links the spec: _service, no _entities' do
      schema = build_subgraph('type Query { hello: String @field(resolver: "Foo") }')

      expect(schema.query.fields.keys).to contain_exactly('hello', '_service')
      expect(schema.types).not_to include('_Entity')
    end
  end

  describe '_entities' do
    let(:sdl) do
      <<~GRAPHQL
        type Query { users: [User!]! @all }

        type User @key(fields: "id") @key(fields: "email") {
          id: ID!
          name: String @external
          email: String
          shout: String @requires(fields: "name") @method
        }

        type Post @key(fields: "user { id } title") {
          id: ID!
          title: String
          user: User @belongsTo
        }
      GRAPHQL
    end

    let(:schema) { build_subgraph(sdl) }

    before do
      LH::User.define_method(:shout) { "#{name.upcase}!" }
    end

    after { LH::User.remove_method(:shout) }

    it "finds a type's records by their keys, in one query for the group" do
      users = Array.new(3) { |i| LH::User.create!(name: "user #{i}", email: "u#{i}@x.test") }
      representations = users.reverse.map { |user| { '__typename' => 'User', 'id' => user.id.to_s } }

      result = nil
      sql = queries_in { result = entities(representations) }

      expect_data(result, '_entities' => users.reverse.map { |user| { '__typename' => 'User', 'id' => user.id.to_s, 'name' => user.name } })
      expect(sql.size).to eq(1)
    end

    it 'uses the first key the representation has' do
      user = LH::User.create!(name: 'Ada', email: 'ada@x.test')

      expect_data(entities([{ '__typename' => 'User', 'email' => 'ada@x.test' }]), '_entities' => [{ 'id' => user.id.to_s }])
    end

    it 'answers null for an entity it does not have' do
      expect(entities([{ '__typename' => 'User', 'id' => '404' }])).to eq('data' => { '_entities' => [nil] })
    end

    it 'sets the @external values the gateway sends on the record, for the @requires field' do
      user = LH::User.create!(name: 'stored', email: 'a@x.test')

      result = entities([{ '__typename' => 'User', 'id' => user.id.to_s, 'name' => 'from the gateway' }],
                        'query($representations: [_Any!]!) { _entities(representations: $representations) { ... on User { shout } } }')

      expect_data(result, '_entities' => [{ 'shout' => 'FROM THE GATEWAY!' }])
      expect(user.reload.name).to eq('stored')
    end

    it 'joins the association a nested key selects' do
      user = LH::User.create!(name: 'Ada')
      LH::Post.create!(title: 'Other', user: LH::User.create!(name: 'Bob'))
      post = LH::Post.create!(title: 'Notes', user: user)

      result = entities([{ '__typename' => 'Post', 'title' => 'Notes', 'user' => { 'id' => user.id.to_s } }])

      expect_data(result, '_entities' => [{ '__typename' => 'Post', 'id' => post.id.to_s }])
    end

    it 'refuses a representation with no key, and an unknown __typename' do
      expect(error_messages(entities([{ '__typename' => 'User',
                                        'name' => 'Ada' }])).first).to include('does not satisfy any set of uniquely identifying keys')
      expect(error_messages(entities([{ '__typename' => 'Nope', 'id' => '1' }]))).to eq(['Unknown __typename `Nope`.'])
    end

    it 'finds the model @model names, and decodes a @globalId key' do
      schema = build_subgraph(<<~GRAPHQL)
        type Query { people: [Person!]! @all }
        type Person @key(fields: "id") @model(class: "User") { id: ID! @globalId name: String }
      GRAPHQL
      user = LH::User.create!(name: 'Ada')

      result = schema.execute('query($r: [_Any!]!) { _entities(representations: $r) { ... on Person { name } } }',
                              variables: { 'r' => [{ '__typename' => 'Person',
                                                     'id' => Lighthouse::GraphQL::GlobalId.encode('Person', user.id) }] }).to_h

      expect(result).to eq('data' => { '_entities' => [{ 'name' => 'Ada' }] })
    end

    it 'answers the representation itself for a type that has no model' do
      schema = build_subgraph(<<~GRAPHQL)
        type Query { a: Int }
        type Review @key(fields: "id") { id: ID! stars: Int }
      GRAPHQL

      result = schema.execute('query($r: [_Any!]!) { _entities(representations: $r) { ... on Review { id stars } } }',
                              variables: { 'r' => [{ '__typename' => 'Review', 'id' => '7', 'stars' => 5 }] }).to_h

      expect(result).to eq('data' => { '_entities' => [{ 'id' => '7', 'stars' => 5 }] })
    end
  end

  describe "a type class's resolve_reference" do
    let(:sdl) do
      <<~GRAPHQL
        type Query { a: Int }
        type User @key(fields: "id") { id: ID! name: String }
      GRAPHQL
    end

    let(:schema) { build_subgraph(sdl) }

    it 'resolves each representation, before the model' do
      stub_const('Types::UserType', Class.new(GraphQL::Schema::Object) do
        include Lighthouse::GraphQL::Type

        def self.resolve_reference(representation, context)
          { id: representation[:id], name: "ref #{representation['id']} for #{context[:who]}" }
        end
      end)

      result = schema.execute('query($r: [_Any!]!) { _entities(representations: $r) { ... on User { name } } }',
                              variables: { 'r' => [{ '__typename' => 'User', 'id' => '1' }] }, context: { who: 'me' }).to_h

      expect(result).to eq('data' => { '_entities' => [{ 'name' => 'ref 1 for me' }] })
    end

    it 'or resolve_references, the group at once' do
      calls = []
      stub_const('Types::UserType', Class.new(GraphQL::Schema::Object) do
        include Lighthouse::GraphQL::Type

        define_singleton_method(:resolve_references) do |representations, _context|
          calls << representations.size
          representations.map { |representation| { id: representation[:id], name: "batched #{representation[:id]}" } }
        end
      end)

      result = schema.execute('query($r: [_Any!]!) { _entities(representations: $r) { ... on User { name } } }',
                              variables: { 'r' => [{ '__typename' => 'User', 'id' => '1' }, { '__typename' => 'User', 'id' => '2' }] }).to_h

      expect(result.dig('data', '_entities')).to eq([{ 'name' => 'batched 1' }, { 'name' => 'batched 2' }])
      expect(calls).to eq([2])
    end
  end

  describe 'an entity interface' do
    let(:sdl) do
      <<~GRAPHQL
        type Query { a: Int }

        interface Named @key(fields: "id") { id: ID! name: String }
        type User implements Named @key(fields: "id") { id: ID! name: String }
        type Team implements Named @key(fields: "id") { id: ID! name: String }
      GRAPHQL
    end

    let(:schema) { build_subgraph(sdl) }

    it "is looked up in its types' models, each record answering as its own type" do
      team = LH::Team.create!(name: 'Core')

      result = schema.execute('query($r: [_Any!]!) { _entities(representations: $r) { __typename ... on Named { name } } }',
                              variables: { 'r' => [{ '__typename' => 'Named', 'id' => team.id.to_s }] }).to_h

      expect(result).to eq('data' => { '_entities' => [{ '__typename' => 'Team', 'name' => 'Core' }] })
    end
  end

  describe '@interfaceObject' do
    let(:schema) do
      build_subgraph(<<~GRAPHQL)
        type Query { a: Int }
        type Named @key(fields: "id") @interfaceObject { id: ID! likes: Int }
      GRAPHQL
    end

    it 'is an entity of its own in the subgraph that declares it' do
      stub_const('Types::NamedType', Class.new(GraphQL::Schema::Object) do
        include Lighthouse::GraphQL::Type

        def likes = object[:id].to_i * 10
      end)

      result = schema.execute('query($r: [_Any!]!) { _entities(representations: $r) { __typename ... on Named { likes } } }',
                              variables: { 'r' => [{ '__typename' => 'Named', 'id' => '4' }] }).to_h

      expect(result).to eq('data' => { '_entities' => [{ '__typename' => 'Named', 'likes' => 40 }] })
    end
  end
end
