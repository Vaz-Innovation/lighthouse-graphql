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
    expect(schema.query.fields).to have_key('widgets')
    expect(Lighthouse::GraphQL::SchemaGenerator.inject_directive_definitions(sdl)).to include('directive @eq', 'directive @orderBy')
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

  it 'injects every built-in directive, so none has to be declared' do
    sdl = <<~GRAPHQL
      type Query {
        widgets(where: _ @whereConditions(columns: ["name"])): [Widget!]! @paginate @builder(class: "WidgetsBuilder")
        widget(id: ID! @eq): Widget @find
        allWidgets: [Widget!]! @all(model: "Widget")
        total: Float @aggregate(model: "Widget", column: "rank", function: "SUM")
        me: Widget @auth
      }

      type Widget {
        id: ID!
        children: [Widget!]! @hasMany(relation: "children")
        parent: Widget @belongsTo
        tags: [Widget!]! @belongsToMany
        label: String @field(resolver: "Labels")
      }
    GRAPHQL

    schema = nil
    expect { schema = build_schema(sdl) }.not_to raise_error
    expect(schema.query.fields).to have_key('widgets')
    names = %w[paginate builder whereConditions find all aggregate auth hasMany belongsTo belongsToMany field]
    expect(Lighthouse::GraphQL::SchemaGenerator.inject_directive_definitions(sdl)).to include(*names.map { |name| "directive @#{name}" })
  end

  describe 'what clients see' do
    let(:schema) do
      build_schema(<<~GRAPHQL)
        "A directive of the app's own, for its clients."
        directive @upper on FIELD

        type Query {
          widgets(name: String @eq, trashed: Boolean): [Widget!]! @all @guard
        }

        type Widget { id: ID! name: String @rename(attribute: "name") }
      GRAPHQL
    end

    it "keeps Lighthouse's directives out of introspection, as PHP Lighthouse's schema holds only the standard and the SDL's own" do
      names = schema.execute('{ __schema { directives { name } } }')['data']['__schema']['directives'].pluck('name')

      expect(names).to contain_exactly('deprecated', 'include', 'oneOf', 'skip', 'specifiedBy', 'upper')
    end

    it 'prints neither their definitions nor their uses, nor the types only they use' do
      expect(schema.to_definition).not_to match(/@(all|eq|guard|rename)\b/)
      expect(schema.to_definition).to include('directive @upper on FIELD', 'widgets(name: String, trashed: Boolean): [Widget!]!')
    end

    it 'rejects an operation that uses one' do
      expect(schema.execute('{ widgets @all { id } }')['errors'].pluck('message')).to eq(['Directive @all is not defined'])
    end
  end
end
