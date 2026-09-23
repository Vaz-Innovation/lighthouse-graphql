# frozen_string_literal: true

class MethodSpecThing
  Item = Class.new do
    def shout = 'HELLO'
    def active? = true
  end

  def self.call(_obj, _args, _ctx)
    Item.new
  end
end

RSpec.describe '@method directive' do
  let(:sdl) do
    <<~GRAPHQL
      directive @field(resolver: String!) on FIELD_DEFINITION

      type Query {
        item: Item @field(resolver: "MethodSpecThing")
      }

      type Item {
        loud: String @method(name: "shout")
        isActive: Boolean @method(name: "active?")
      }
    GRAPHQL
  end

  it 'resolves a field by calling the named method on the parent (including predicates)' do
    schema = build_schema(sdl)

    result = schema.execute('{ item { loud isActive } }', context: {})

    expect(result['errors']).to be_nil
    expect(result.dig('data', 'item', 'loud')).to eq('HELLO')
    expect(result.dig('data', 'item', 'isActive')).to be(true)
  end
end
