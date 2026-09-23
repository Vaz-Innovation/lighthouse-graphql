# frozen_string_literal: true

# Resolver returning a plain object that only exposes the snake_case attribute,
# so the default reader must bridge the camelCase GraphQL field to it.
class DefaultReaderSpecContact
  Row = Struct.new(:custom_attributes)

  def self.call(_obj, _args, _ctx)
    Row.new('{"vip":true}')
  end
end

RSpec.describe 'Default field reader casing' do
  let(:sdl) do
    <<~GRAPHQL
      directive @field(resolver: String!) on FIELD_DEFINITION

      type Query {
        contact: Contact @field(resolver: "DefaultReaderSpecContact")
      }

      type Contact {
        customAttributes: String
      }
    GRAPHQL
  end

  it 'resolves a camelCase field with no directive off the snake_case attribute' do
    schema = build_schema(sdl)

    result = schema.execute('{ contact { customAttributes } }', context: {})

    expect(result['errors']).to be_nil
    expect(result.dig('data', 'contact', 'customAttributes')).to eq('{"vip":true}')
  end
end
