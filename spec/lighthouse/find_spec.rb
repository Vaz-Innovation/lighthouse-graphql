# frozen_string_literal: true

RSpec.describe '@find directive' do
  # The model is inferred from the return type, and the lookup is batched
  # through the Dataloader, as in an app schema.
  let(:schema) do
    Lighthouse::GraphQL::SchemaFactory.build_base_schema(
      sdl: <<~GRAPHQL,
        type Query {
          widget(id: ID! @eq): Widget @find
        }

        type Widget {
          id: ID!
          name: String
        }
      GRAPHQL
      schema_options: { using: { GraphQL::Dataloader => {} } }
    )
  end

  it 'finds a record of the inferred model by its ID argument, which arrives as a string' do
    widget = Widget.create!(name: 'sprocket')

    result = schema.execute("{ widget(id: \"#{widget.id}\") { name } }").to_h

    expect(result).to eq('data' => { 'widget' => { 'name' => 'sprocket' } })
  end

  it 'returns null when no record matches' do
    expect(schema.execute('{ widget(id: "0") { name } }').to_h).to eq('data' => { 'widget' => nil })
  end
end
