# frozen_string_literal: true

# Returns an object whose attribute name differs from the GraphQL field name, so
# @rename must bridge them explicitly.
class RenameSpecRow
  Row = Struct.new(:legal_name)

  def self.call(_obj, _args, _ctx)
    Row.new('ACME Inc')
  end
end

RSpec.describe '@rename directive' do
  let(:sdl) do
    <<~GRAPHQL
      directive @field(resolver: String!) on FIELD_DEFINITION
      directive @rename(attribute: String!) on FIELD_DEFINITION

      type Query {
        org: Org @field(resolver: "RenameSpecRow")
      }

      type Org {
        displayName: String @rename(attribute: "legal_name")
      }
    GRAPHQL
  end

  it 'reads the explicitly renamed attribute, ignoring the field name' do
    schema = build_schema(sdl)

    result = schema.execute('{ org { displayName } }', context: {})

    expect(result['errors']).to be_nil
    expect(result.dig('data', 'org', 'displayName')).to eq('ACME Inc')
  end
end
