# frozen_string_literal: true

RSpec.describe 'Federation resolve_reference binding' do
  let(:sdl) do
    <<~GRAPHQL
      type Query {
        widget: Widget
      }

      type Widget @key(fields: "id") {
        id: ID!
        name: String
      }
    GRAPHQL
  end

  let(:schema) { build_federated_schema(sdl) }
  let(:widget_type) { schema.get_type('Widget') }

  after { Lighthouse::ReferenceResolver.clear! }

  it 'binds @key entities for federation' do
    expect(widget_type.respond_to?(:resolve_reference)).to be(true)
  end

  it 'falls back to the base type resolve_reference (model lookup) without a custom handler' do
    widget = Widget.create!(name: 'Acme')

    resolved = widget_type.resolve_reference({ 'id' => widget.id.to_s }, {})

    expect(resolved).to eq(widget)
  end

  it 'prefers a registered ReferenceResolver handler over the default lookup' do
    widget = Widget.create!(name: 'Acme')
    Lighthouse::ReferenceResolver.register('Widget') { |reference, _ctx| "custom:#{reference['id']}" }

    expect(widget_type.resolve_reference({ 'id' => widget.id.to_s }, {})).to eq("custom:#{widget.id}")
  end
end
