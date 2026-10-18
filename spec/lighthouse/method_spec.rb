# frozen_string_literal: true

class MethodSpecThing
  Item = Class.new do
    def shout = 'HELLO'
    def active? = true
    def greet(name:, punctuation: '.') = "Hi #{name}#{punctuation}"
    def repeat(word, times) = ([word] * times).join(' ')
    def splat(*parts) = parts.compact.join('+')
    def options(**opts) = opts.keys.sort.join(',')
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
        greet(name: String!, punctuation: String = "!"): String @method
        repeat(word: String!, times: Int = 2): String @method
        splat(a: String, b: String): String @method
        options(first: Int, second: Int = 2): String @method
        ignoring(extra: Int): String @method(name: "shout")
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

  it 'passes the arguments as keywords to a method taking keywords, with the SDL defaults' do
    result = build_schema(sdl).execute('{ item { greet(name: "Ada") formal: greet(name: "Ada", punctuation: ".") options(first: 1) } }')

    expect(result.dig('data', 'item')).to eq('greet' => 'Hi Ada!', 'formal' => 'Hi Ada.', 'options' => 'first,second')
  end

  it 'passes them positionally, in SDL order, to a method taking positional parameters' do
    result = build_schema(sdl).execute('{ item { repeat(word: "go") thrice: repeat(word: "go", times: 3) splat(b: "y", a: "x") } }')

    expect(result.dig('data', 'item')).to eq('repeat' => 'go go', 'thrice' => 'go go go', 'splat' => 'x+y')
  end

  it 'calls a method taking no parameters without them' do
    expect(build_schema(sdl).execute('{ item { ignoring(extra: 1) } }').dig('data', 'item', 'ignoring')).to eq('HELLO')
  end
end
