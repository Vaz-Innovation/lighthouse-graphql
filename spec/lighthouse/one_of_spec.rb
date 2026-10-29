# frozen_string_literal: true

RSpec.describe 'OneOf input objects' do
  let(:sdl) do
    <<~GRAPHQL
      input WidgetBy @oneOf {
        id: ID @eq
        name: String @eq
      }

      type Widget { id: ID! name: String }

      type Query {
        widget(by: WidgetBy!): Widget @find
        widgets(by: WidgetBy): [Widget!]! @all
      }
    GRAPHQL
  end
  let(:schema) { build_schema(sdl) }
  let!(:widget) { Widget.create!(name: 'beta') }

  before { Widget.create!(name: 'alpha') }

  def errors(result) = result['errors'].map { |error| error['message'] }

  it 'reports isOneOf through introspection' do
    result = schema.execute('{ __type(name: "WidgetBy") { isOneOf } }')

    expect(result['data']['__type']).to eq('isOneOf' => true)
  end

  it 'filters by whichever field the client gave' do
    by_name = schema.execute('{ widget(by: { name: "beta" }) { id } }')
    by_id = schema.execute(%({ widget(by: { id: "#{widget.id}" }) { name } }))

    expect(by_name['data']['widget']).to eq('id' => widget.id.to_s)
    expect(by_id['data']['widget']).to eq('name' => 'beta')
    expect(schema.execute('{ widgets(by: { name: "alpha" }) { name } }')['data']['widgets']).to eq([{ 'name' => 'alpha' }])
  end

  it 'rejects a literal with more or fewer than one field, or with a null' do
    expect(errors(schema.execute('{ widget(by: { id: "1", name: "beta" }) { id } }')))
      .to eq(["OneOf Input Object 'WidgetBy' must specify exactly one key."])
    expect(errors(schema.execute('{ widget(by: {}) { id } }')))
      .to eq(["OneOf Input Object 'WidgetBy' must specify exactly one key."])
    expect(errors(schema.execute('{ widget(by: { name: null }) { id } }')))
      .to eq(["Argument 'WidgetBy.name' must be non-null."])
  end

  it 'rejects a variable with more than one field' do
    result = schema.execute('query($by: WidgetBy!) { widget(by: $by) { id } }', variables: { 'by' => { 'id' => '1', 'name' => 'beta' } })

    expect(result['errors'].first['extensions']['problems'].first['explanation'])
      .to eq("'WidgetBy' requires exactly one argument, but 2 were provided.")
  end

  context 'when the SDL declares the built-in directives' do
    let(:sdl) do
      <<~GRAPHQL
        directive @oneOf on INPUT_OBJECT
        directive @skip(if: Boolean!) on FIELD | FRAGMENT_SPREAD | INLINE_FRAGMENT

        input WidgetBy @oneOf { id: ID @eq name: String @eq }

        type Widget { id: ID! name: String }

        type Query {
          widget(by: WidgetBy!): Widget @find
        }
      GRAPHQL
    end

    it "keeps graphql-ruby's, which validate and skip" do
      expect(schema.get_type('WidgetBy').one_of?).to be(true)
      expect(errors(schema.execute('{ widget(by: { id: "1", name: "beta" }) { id } }')))
        .to eq(["OneOf Input Object 'WidgetBy' must specify exactly one key."])
      expect(schema.execute('{ widget(by: { name: "beta" }) { id name @skip(if: true) } }')['data']['widget'])
        .to eq('id' => widget.id.to_s)
    end
  end
end
