# frozen_string_literal: true

module ConvertEmptyStringsSpec
  # Records the arguments a @field resolver receives, as plain Ruby values.
  class Spy
    class << self
      attr_accessor :received

      def call(_obj, args, _ctx)
        self.received = Lighthouse::Support::Arguments.plain(args)
        'ok'
      end
    end
  end

  class Echo < GraphQL::Schema::Resolver
    type String, null: true
    argument :text, String, required: false

    def resolve(text: nil) = text.nil? ? 'nil' : "text:#{text}"
  end
end

RSpec.describe '@convertEmptyStringsToNull' do
  let(:sdl) do
    <<~GRAPHQL
      type Query {
        onArg(title: String @convertEmptyStringsToNull, other: String): String @field(resolver: "ConvertEmptyStringsSpec::Spy")
        onNonNullArg(title: String! @convertEmptyStringsToNull): String @field(resolver: "ConvertEmptyStringsSpec::Spy")
        onInputField(input: Marked): String @field(resolver: "ConvertEmptyStringsSpec::Spy")
        onField(title: String, strict: String!, tags: [String], strictTags: [String!], input: Deep, inputs: [Deep!]): String
          @convertEmptyStringsToNull @field(resolver: "ConvertEmptyStringsSpec::Spy")
        plain(title: String, input: Deep): String @field(resolver: "ConvertEmptyStringsSpec::Spy")
        forced(tags: [String!] @convertEmptyStringsToNull): String @field(resolver: "ConvertEmptyStringsSpec::Spy")
        echo(text: String): String @convertEmptyStringsToNull
      }

      input Marked { name: String @convertEmptyStringsToNull, bio: String, strict: String! @convertEmptyStringsToNull }
      input Deep { name: String, strict: String!, tags: [String], child: Deep }
    GRAPHQL
  end
  let(:schema) { build_schema(sdl) }

  before { ConvertEmptyStringsSpec::Spy.received = nil }

  def received = ConvertEmptyStringsSpec::Spy.received

  def run(query, schema: self.schema)
    schema.execute(query).tap { |result| expect(result['errors']).to be_nil, result['errors'].inspect }
  end

  it 'injects the directive definition' do
    expect(Lighthouse::GraphQL::SchemaGenerator.inject_directive_definitions(sdl)).to include('directive @convertEmptyStringsToNull')
  end

  describe 'on an argument' do
    it 'converts that argument only' do
      run('{ onArg(title: "", other: "") }')
      expect(received).to eq(title: nil, other: '')
    end

    it 'leaves other values unchanged' do
      run('{ onArg(title: "x") }')
      expect(received).to eq(title: 'x')
    end

    it 'converts a non-null argument too' do
      run('{ onNonNullArg(title: "") }')
      expect(received).to eq(title: nil)
    end

    it 'converts the items of a list when forced' do
      run('{ forced(tags: ["a", ""]) }')
      expect(received).to eq(tags: ['a', nil])
    end
  end

  describe 'on an input field' do
    it 'converts it wherever the input type is used, including non-null fields' do
      run('{ onInputField(input: { name: "", bio: "", strict: "" }) }')
      expect(received).to eq(input: { name: nil, bio: '', strict: nil })
    end
  end

  describe 'on a field' do
    it 'converts every nullable input, recursively through input objects and lists' do
      run(<<~GRAPHQL)
        { onField(
            title: "", strict: "", tags: ["a", "", "b"], strictTags: ["", "c"],
            input: { name: "", strict: "", tags: [""], child: { name: "", strict: "", child: { name: "" , strict: "z"} } },
            inputs: [{ name: "", strict: "" }, { name: "n", strict: "s" }]
          ) }
      GRAPHQL

      expect(received).to eq(
        title: nil, strict: '', tags: ['a', nil, 'b'], strict_tags: ['', 'c'],
        input: { name: nil, strict: '', tags: [nil], child: { name: nil, strict: '', child: { name: nil, strict: 'z' } } },
        inputs: [{ name: nil, strict: '' }, { name: 'n', strict: 's' }]
      )
    end

    it 'hands inner resolvers the same kinds of arguments: input objects stay input objects' do
      received_types = nil
      stub_const('ConvertEmptyStringsSpec::Types', Class.new do
        define_singleton_method(:call) do |_o, args, _c|
          received_types = [args.class, args[:input].class.ancestors.include?(GraphQL::Schema::InputObject), args[:input][:name]]
          'ok'
        end
      end)
      typed = build_schema(<<~GRAPHQL)
        type Query { x(input: In): String @convertEmptyStringsToNull @field(resolver: "ConvertEmptyStringsSpec::Types") }
        input In { name: String }
      GRAPHQL

      run('{ x(input: { name: "" }) }', schema: typed)
      expect(received_types).to eq([Hash, true, nil])
    end

    it 'keeps explicit nulls and omitted arguments as they are' do
      run('{ onField(strict: "s", title: null) }')
      expect(received).to eq(title: nil, strict: 's')
    end
  end

  describe 'sharing an input type' do
    it 'does not affect a field without the directive' do
      run('{ plain(title: "", input: { name: "", strict: "" }) }')
      expect(received).to eq(title: '', input: { name: '', strict: '' })

      run('{ onField(strict: "", input: { name: "", strict: "" }) }')
      expect(received).to eq(strict: '', input: { name: nil, strict: '' })
    end
  end

  describe 'Config.convert_empty_strings_to_null' do
    it 'converts the nullable inputs of every field' do
      Lighthouse::Config.convert_empty_strings_to_null = true
      global = build_schema(sdl)

      run('{ plain(title: "", input: { name: "", strict: "" }) }', schema: global)
      expect(received).to eq(title: nil, input: { name: nil, strict: '' })
    end

    it 'is off by default' do
      expect(Lighthouse::Config.convert_empty_strings_to_null).to be(false)
    end
  end

  describe 'with every kind of resolver' do
    let(:sdl) do
      <<~GRAPHQL
        type Query {
          posts(title: String @eq): [Post!]! @all
          echo(text: String): String @convertEmptyStringsToNull
          greet(name: String): String
        }
        type Mutation {
          createPost(title: String @convertEmptyStringsToNull): Post @create
          createPostInput(input: PostInput! @spread): Post @create
          createWithBody(title: String!, body: String @convertEmptyStringsToNull): Post @create
          createWithRawBody(title: String!, body: String): Post @create
          validated(title: String @convertEmptyStringsToNull): String @validator(class: "ConvertEmptyStringsSpec::Contract") @field(resolver: "ConvertEmptyStringsSpec::Spy")
        }
        type Post { id: ID! title: String body: String }
        input PostInput { title: String @convertEmptyStringsToNull, body: String }
      GRAPHQL
    end

    before do
      stub_const('ConvertEmptyStringsSpec::Contract', Class.new { def call(values) = values[:title].nil? ? {} : { title: ['not blank'] } })
      stub_const('Resolvers::Echo', ConvertEmptyStringsSpec::Echo)
      stub_const('Resolvers::Greet', Class.new(GraphQL::Schema::Resolver) do
        type String, null: true
        argument :name, String, required: false
        def resolve(name: nil) = name.nil? ? 'nil' : "name:#{name}"
      end)
    end

    it 'reaches @create: the blank title fails the model validation' do
      result = schema.execute('mutation { createPost(title: "") { id } }')

      expect(result.to_h.to_s).to include("can't be blank")
      expect(Post.count).to eq(0)
    end

    it 'reaches @create through a @spread input field' do
      result = schema.execute('mutation { createPostInput(input: { title: "", body: "b" }) { id } }')

      expect(result.to_h.to_s).to include("can't be blank")
      expect(Post.count).to eq(0)
    end

    it 'reaches @create: the record stores null for an emptied attribute' do
      run('mutation { createWithBody(title: "t", body: "") { id } }')
      run('mutation { createWithRawBody(title: "t", body: "") { id } }')

      expect(Post.order(:id).pluck(:body)).to eq([nil, ''])
    end

    it 'reaches @validator' do
      expect(run('mutation { validated(title: "") }')['data']).to eq('validated' => 'ok')
      expect(received).to eq(title: nil)
    end

    it 'reaches an @eq filter on @all: an empty string no longer filters' do
      Post.create!(title: 'a')
      Post.create!(title: 'b')
      schema_all = build_schema(<<~GRAPHQL)
        type Query { posts(title: String @eq @convertEmptyStringsToNull): [Post!]! @all }
        type Post { id: ID! title: String }
      GRAPHQL

      expect(run('{ posts(title: "") { title } }', schema: schema_all)['data']['posts'].size).to eq(2)
      expect(run('{ posts(title: "a") { title } }', schema: schema_all)['data']['posts']).to eq([{ 'title' => 'a' }])
    end

    it 'still filters on empty strings without the directive' do
      Post.create!(title: 'a')
      plain = build_schema(<<~GRAPHQL)
        type Query { posts(title: String @eq): [Post!]! @all }
        type Post { id: ID! title: String }
      GRAPHQL

      expect(run('{ posts(title: "") { title } }', schema: plain)['data']['posts']).to eq([])
    end

    it 'reaches a convention Resolvers:: resolver, given a field-level directive' do
      expect(run('{ echo(text: "") }')['data']).to eq('echo' => 'nil')
      expect(run('{ echo(text: "hi") }')['data']).to eq('echo' => 'text:hi')
    end

    it 'reaches a convention resolver under the global setting, and not without it' do
      expect(run('{ greet(name: "") }')['data']).to eq('greet' => 'name:')

      Lighthouse::Config.convert_empty_strings_to_null = true
      expect(run('{ greet(name: "") }', schema: build_schema(sdl))['data']).to eq('greet' => 'nil')
    end

    it 'reaches the default reader chain without breaking a field that has no resolver directive' do
      Post.create!(title: 'a')
      plain = build_schema(<<~GRAPHQL)
        type Query { first(title: String @convertEmptyStringsToNull): Post @first }
        type Post { id: ID! title: String }
      GRAPHQL

      expect(run('{ first(title: "") { title } }', schema: plain)['data']['first']).to eq('title' => 'a')
    end
  end
end
