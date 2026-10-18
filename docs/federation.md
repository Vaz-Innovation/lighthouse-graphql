# Apollo Federation

Lighthouse lets a Rails service act as an [Apollo Federation](https://www.apollographql.com/docs/federation/)
**subgraph**: it understands the federation directives in your SDL and wires up
entity resolution so a gateway can compose your types with other subgraphs.

This relies on the [`apollo-federation`](https://github.com/Gusto/apollo-federation-ruby)
gem, which you include in your app's base types and schema.

## Setup

Include the federation mixins in the base types you pass to Lighthouse, and make
your schema a federation schema:

```ruby
# app/graphql/types/base_object.rb
class Types::BaseObject < GraphQL::Schema::Object
  include ApolloFederation::Object

  # Default entity resolution: look the record up by id on the model that shares
  # the type's GraphQL name. Lighthouse falls back to this when no custom
  # resolver is registered (see below).
  def self.resolve_reference(reference, _context)
    model = graphql_name.safe_constantize
    return nil unless model&.respond_to?(:find_by)

    model.find_by(id: reference[:id] || reference['id'])
  end
end

BaseAppSchema = Lighthouse::GraphQL::RbLightHouse.get_schema(
  schema_path: Rails.root.join('graphql/schema.graphql').to_s,
  options: { federation: true, base_types: { object: Types::BaseObject, resolver: Resolvers::BaseResolver } }
)

class AppSchema < BaseAppSchema
  include ApolloFederation::Schema
  federation(version: '2.3')
  query(superclass.query)
end
```

## Declaring entities

Mark a type as a federation entity with `@key`. Lighthouse recognizes the
federation directives during the resolution phase and applies them:

```graphql
type User @key(fields: "id") {
  id: ID!
  name: String
}

type Order @key(fields: "id") @shareable {
  id: ID!
}
```

Supported object-level directives: `@key`, `@extends`, `@shareable`,
`@inaccessible`. Field-level `@external` is recognized for federation composition.

## Entity resolution (`resolve_reference`)

When the gateway asks your subgraph to resolve an entity (via `_entities`),
Lighthouse routes to a `resolve_reference` it installs on each `@key` type. The
order of precedence is:

1. **A custom resolver** registered with `Lighthouse::ReferenceResolver` for that
   type, if any.
2. **The base type's `resolve_reference`** otherwise (e.g. the default
   model-lookup-by-id shown above).

This means direct-model entities resolve with **zero extra code** — the default
lookup handles them — while you register custom resolvers only for the entities
that need bespoke loading.

### Custom reference resolvers

For entities that aren't a straightforward `find_by(id:)` — for example, ones
backed by a join or an external identifier — register a resolver. The single best
place is an initializer:

```ruby
# config/initializers/federation.rb
Rails.application.config.to_prepare do
  Lighthouse::ReferenceResolver.register('JudgmentCreditor') do |reference, _context|
    id = reference['id'] || reference[:id]
    OpenStruct.new(id: id, contacts: Contact.joins(:links).where(links: { external_id: id }))
  end
end
```

`register(typename) { |reference, context| ... }` returns the object that
represents the entity; its fields then resolve normally.

## The federation subgraph SDL

A federation subgraph publishes its capabilities via the `_service { sdl }` field
(and `federation_sdl`), which a gateway uses to compose the supergraph. With the
setup above this is produced for you, including the `@link` to the federation spec
and the `@key`/`@shareable`/… directives on your types.

## Gateways

Apollo Gateways that use `IntrospectAndCompose` poll subgraphs and recompose
automatically when your subgraph SDL changes — no manual step needed when you
deploy schema changes. Gateways that consume a static, pre-composed supergraph
file need that file recomposed (e.g. via `rover supergraph compose`) after you
change the subgraph.
