# frozen_string_literal: true

# Field that returns a fixed string (for @guard).
class AuthSpecConst
  def self.call(_obj, _args, _ctx)
    'ok'
  end
end

# Field that returns a record (responds to #id) or nil (for @can).
class AuthSpecThing
  Row = Struct.new(:id, :secret)

  def self.call(_obj, args, _ctx)
    id = (args[:id] || args['id']).to_i
    id.zero? ? nil : Row.new(id, 'top-secret')
  end
end

RSpec.describe 'Authorization directives (@guard / @can)' do
  after { Lighthouse::Config.reset! }

  let(:sdl) do
    <<~GRAPHQL
      directive @field(resolver: String!) on FIELD_DEFINITION

      type Query {
        secret: String @field(resolver: "AuthSpecConst") @guard
        thing(id: ID!): Thing @field(resolver: "AuthSpecThing") @can(ability: "show")
      }

      type Thing {
        id: ID!
        secret: String
      }
    GRAPHQL
  end

  let(:schema) { build_schema(sdl) }

  before do
    Lighthouse.configure do |c|
      c.authenticated_user = ->(ctx) { ctx[:current_user] }
      c.policy_user = ->(ctx) { ctx[:current_user] }
      # Test authorizer: the "user" hash carries an :allow flag.
      c.authorizer = ->(user, _record, _ability) { user && user[:allow] }
    end
  end

  describe '@guard' do
    it 'rejects an unauthenticated request' do
      result = schema.execute('{ secret }', context: {})
      expect(result.dig('data', 'secret')).to be_nil
      expect(result['errors'].first['message']).to eq('Unauthenticated.')
    end

    it 'allows an authenticated request' do
      result = schema.execute('{ secret }', context: { current_user: { allow: true } })
      expect(result['errors']).to be_nil
      expect(result.dig('data', 'secret')).to eq('ok')
    end
  end

  describe '@can' do
    it 'returns the record when the ability is granted' do
      result = schema.execute('{ thing(id: 1) { id secret } }', context: { current_user: { allow: true } })
      expect(result['errors']).to be_nil
      expect(result.dig('data', 'thing', 'secret')).to eq('top-secret')
    end

    it 'raises when the ability is denied' do
      result = schema.execute('{ thing(id: 1) { id } }', context: { current_user: { allow: false } })
      expect(result.dig('data', 'thing')).to be_nil
      expect(result['errors'].first['message']).to eq('You are not authorized to perform this action.')
    end

    it 'passes through a nil result without authorizing' do
      result = schema.execute('{ thing(id: 0) { id } }', context: { current_user: { allow: false } })
      expect(result['errors']).to be_nil
      expect(result.dig('data', 'thing')).to be_nil
    end
  end

  it 'injects @guard and @can SDL definitions automatically' do
    expect(schema.directives.keys).to include('guard', 'can')
  end
end
