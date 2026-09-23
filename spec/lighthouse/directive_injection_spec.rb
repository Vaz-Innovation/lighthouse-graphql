# frozen_string_literal: true

RSpec.describe 'Programmatic directive SDL injection' do
  it 'builds a schema using registered directives that the app did not declare' do
    # @all is declared (legacy directive), but @eq and @orderBy are NOT — the
    # registry must inject their definitions so the build succeeds.
    sdl = <<~GRAPHQL
      directive @all(model: String) on FIELD_DEFINITION

      type Query {
        widgets(
          email: String @eq
          orderBy: [Mixed] @orderBy
        ): [Widget!]! @all(model: "Widget")
      }

      type Widget {
        id: ID!
        email: String
      }

      scalar Mixed
    GRAPHQL

    schema = nil
    expect { schema = build_schema(sdl) }.not_to raise_error
    expect(schema.directives.keys).to include('eq', 'orderBy')
  end

  it 'does not duplicate a directive the app already declared' do
    sdl = <<~GRAPHQL
      directive @eq(key: String) on ARGUMENT_DEFINITION
      directive @all(model: String) on FIELD_DEFINITION

      type Query {
        widgets(email: String @eq): [Widget!]! @all(model: "Widget")
      }

      type Widget {
        id: ID!
        email: String
      }
    GRAPHQL

    expect { build_schema(sdl) }.not_to raise_error
  end
end
