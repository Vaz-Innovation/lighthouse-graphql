# frozen_string_literal: true

# The schema and expected headers are PHP Lighthouse's own @cacheControl example.
RSpec.describe '@cacheControl' do
  let(:sdl) do
    <<~GRAPHQL
      type User {
        tasks: [Task!]! @field(resolver: "CacheControlSpecTasks") @cacheControl(maxAge: 50, scope: PUBLIC)
      }

      type Company @cacheControl(maxAge: 40, scope: PUBLIC) {
        users: [User!]! @field(resolver: "CacheControlSpecUsers") @cacheControl(maxAge: 25, scope: PUBLIC)
        owner: User @field(resolver: "CacheControlSpecUser")
      }

      type Task {
        id: ID @cacheControl(maxAge: 10, scope: PUBLIC)
        name: String @cacheControl(maxAge: 0, inheritMaxAge: true)
        description: String @cacheControl
      }

      type Query {
        me: User! @field(resolver: "CacheControlSpecUser") @cacheControl(maxAge: 5, scope: PRIVATE)
        companies: [Company!]! @field(resolver: "CacheControlSpecCompanies")
        publicCompanies: [Company!]! @field(resolver: "CacheControlSpecCompanies") @cacheControl(maxAge: 15)
        firstCompany: Company @field(resolver: "CacheControlSpecCompany") @cacheControl(maxAge: 30)
      }

      type Mutation {
        touch: Boolean @field(resolver: "CacheControlSpecTrue") @cacheControl(maxAge: 100)
      }
    GRAPHQL
  end

  let(:schema) { build_schema(sdl) }

  before do
    task = { 'id' => '1', 'name' => 'n', 'description' => 'd' }
    stub_const('CacheControlSpecTasks', Class.new { define_singleton_method(:call) { |*| [task] } })
    stub_const('CacheControlSpecUser', Class.new { def self.call(*) = {} })
    stub_const('CacheControlSpecUsers', Class.new { def self.call(*) = [{}] })
    stub_const('CacheControlSpecCompany', Class.new { def self.call(*) = {} })
    stub_const('CacheControlSpecCompanies', Class.new { def self.call(*) = [{}] })
    stub_const('CacheControlSpecTrue', Class.new { def self.call(*) = true })
  end

  def header(query)
    result = schema.execute(query)
    raise result['errors'].inspect if result['errors']

    Lighthouse::GraphQL::CacheControl.header(result)
  end

  {
    '{ me { tasks { id } } }' => 'max-age=5, private',
    '{ me { tasks { description } } }' => 'no-cache, private',
    '{ companies { users { tasks { id } } } }' => 'no-cache, private',
    '{ publicCompanies { users { tasks { id } } } }' => 'max-age=10, public',
    '{ publicCompanies { users { tasks { name } } } }' => 'max-age=15, public'
  }.each do |query, expected|
    it "sends #{expected.inspect} for #{query}" do
      expect(header(query)).to eq(expected)
    end
  end

  it "uses the return type's @cacheControl for a field without one, and the field's own over it" do
    expect(header('{ firstCompany { owner { tasks { id } } } }')).to eq('no-cache')
    expect(header('{ firstCompany { users { tasks { id } } } }')).to eq('max-age=10, public')
  end

  it 'counts fields selected through fragments' do
    query = <<~GRAPHQL
      { publicCompanies { ...CompanyUsers } }
      fragment CompanyUsers on Company { users { tasks { ...TaskBits } } }
      fragment TaskBits on Task { id }
    GRAPHQL

    expect(header(query)).to eq('max-age=10, public')
  end

  it 'never caches a mutation' do
    expect(header('mutation { touch }')).to eq('no-cache')
  end

  it 'sets the header on a response' do
    response = Struct.new(:headers).new({})
    Lighthouse::GraphQL::CacheControl.apply(response, schema.execute('{ publicCompanies { users { tasks { id } } } }'))

    expect(response.headers).to eq('Cache-Control' => 'max-age=10, public')
  end

  it 'computes nothing for a schema without @cacheControl' do
    plain = build_schema("type Query { a: String @field(resolver: \"CacheControlSpecTrue\") }")

    expect(Lighthouse::GraphQL::CacheControl.header(plain.execute('{ a }'))).to be_nil
  end
end
