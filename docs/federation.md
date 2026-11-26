# Apollo Federation

Lighthouse lets a Rails app be an [Apollo Federation](https://www.apollographql.com/docs/federation/)
**subgraph**: a gateway, such as [Apollo Router](https://www.apollographql.com/docs/graphos/routing),
composes its schema with other subgraphs' into one supergraph, and asks each
subgraph for its part of every query. As in PHP Lighthouse, it takes no Ruby:
the SDL says it.

The repository's [`examples/graphql-federations`](https://github.com/Vaz-Innovation/lighthouse-graphql/tree/main/examples/graphql-federations)
is two subgraphs (two Rails apps) behind Apollo Router and behind GraphQL Yoga,
with an end-to-end suite that drives every feature on this page through the
router, and the graph through Yoga, which subscribes over Server-Sent Events.

## A subgraph

Link the Federation 2 spec, importing the directives you use, and mark your
entities with `@key`:

```graphql
extend schema
  @link(url: "https://specs.apollo.dev/federation/v2.9", import: ["@key", "@shareable", "@external", "@requires"])

type Query {
  user(id: ID! @eq): User @find
}

type User @key(fields: "id") {
  id: ID!
  name: String!
}
```

That is all. While the schema is built, Lighthouse:

- declares the spec's directives the SDL uses (you don't write `directive @key ...`),
  under the names the link gives them: an imported one keeps its name, or the
  one `import: [{ name: "@key", as: "@id" }]` gives it; any other is prefixed,
  `@federation__shareable` (or with the link's `as:`);
- adds what the spec asks of a subgraph: `scalar _Any`, `type _Service { sdl: String! }`,
  `Query._service` and, when an object type has `@key`, `union _Entity` of them
  and `Query._entities(representations: [_Any!]!): [_Entity]!`;
- makes the types `@paginate` generates (`PaginatorInfo`, `PageInfo`, `UserPaginator`,
  `UserConnection`, ...) `@shareable`: every subgraph that paginates generates the
  same ones, which composition would otherwise refuse.

A schema without the link is a Federation 1 subgraph when you ask for one with
`get_schema(options: { federation: true })`: its directives keep their names,
and nothing is `@shareable` (Federation 1 has no such directive).

Nothing changes in the app's schema class: no mixin, no plugin.

```ruby
class AppSchema < Lighthouse::GraphQL::RbLightHouse.get_schema(options: { base_types: { ... } })
  use GraphQL::Dataloader
end
```

## The subgraph SDL

`Query._service { sdl }` answers the subgraph's SDL, which the gateway (or
`rover supergraph compose`) composes. It is the schema clients see, printed as
PHP Lighthouse's FederationPrinter prints it:

- with its `extend schema @link(...)` (and `@composeDirective`, and the links of
  your own directives);
- with every directive it applies, on every kind of member: types, fields,
  arguments, enum values, input fields, scalars, unions (`@tag` and
  `@inaccessible` go anywhere);
- without Lighthouse's own directives (`@all`, `@paginate`, `@guard`, ...), which
  are the server's;
- without what the spec adds (`_Any`, `_Entity`, `_Service`, `_entities`,
  `_service`, and `Query` when it has no other field) or declares (the spec's
  directive definitions): the gateway knows them from the link. A directive of
  your own keeps its definition.

Print it with the rake task, or read it from the schema:

```shell
FORMAT=federation bin/rails lighthouse:print_schema > accounts.graphql
```

```ruby
AppSchema.federation_sdl
```

## Entities

The gateway asks a subgraph for the entities it has a part of with
`_entities(representations:)`: a list of `{ "__typename": "User", "id": "1" }`.
Lighthouse groups them by type, and resolves each group once, by, in order:

1. **The type class's `resolve_references` or `resolve_reference`.** The class of
   the type (`Types::UserType`, including `Lighthouse::GraphQL::Type`; see
   [types.md](types.md)), as graphql-ruby's federation does it:

   ```ruby
   class Types::UserType < Types::BaseObject
     # The group at once: an Array, in the representations' order.
     def self.resolve_references(representations, context)
       users = User.where(external_id: representations.pluck(:id)).index_by(&:external_id)
       representations.map { |representation| users[representation[:id]] }
     end

     # Or one at a time.
     def self.resolve_reference(representation, context) = User.find_by(external_id: representation[:id])
   end
   ```

   A representation reads with string or symbol keys alike.

2. **The type's model**: its `@model(class:)`, else the model of its name. It is
   queried by the first `@key` whose fields the representation has, as PHP
   Lighthouse does, but in one query for the whole group:
   `User.where(id: [...])`, or `where(...).or(where(...))` for a compound key.
   - A key field reads the column of its name in snake_case, or its `@rename(attribute:)`.
   - A key field with `@globalId` is decoded first.
   - A nested selection (`@key(fields: "author { id }")`) joins the association
     of that name.
   - The values the gateway sends for the type's `@external` fields (those a
     `@requires` asks for) are set on each record (never saved), so the field
     that requires them reads them as attributes: `@requires(fields: "name")` on
     `signature` and a `User#signature` that reads `name`.

3. **The representation itself**, for a type with no class method and no model:
   its fields read the representation's values (`id`, and whatever `@requires`
   brought), or are resolved by its type class's methods.

An entity a subgraph does not have is `null`, as the spec allows. A representation
that has none of the type's keys, or names a type the subgraph does not have, is
an error.

### Entity interfaces and `@interfaceObject`

An interface may be an entity too (Federation 2.3):

```graphql
# The subgraph that owns the interface: every implementation is an entity with its key.
interface Authored @key(fields: "id") { id: ID! author: User! }
type Post implements Authored @key(fields: "id") { ... }
type Comment implements Authored @key(fields: "id") { ... }
```

```graphql
# Another subgraph adds fields to every Authored, knowing none of its types.
type Authored @key(fields: "id") @interfaceObject {
  id: ID!
  likesCount: Int!
}
```

The router asks the owning subgraph for `{ "__typename": "Authored", "id": ... }`
when it needs the concrete type: Lighthouse resolves the interface with its type
class's `resolve_reference(s)`, else looks the representation up in the model of
each type that implements it, in turn, and answers each record as the type it
resolves to (see [types.md](types.md)). The key must tell the implementations
apart: UUIDs, unique across the tables, do. In the subgraph that declares the
`@interfaceObject`, `Authored` is an object type like any other, usually with no
model: its fields are resolved from the representation by its type class.

## The federation directives

Lighthouse passes every directive of the spec through to the gateway; what it
does itself:

| Directive | Lighthouse |
| --- | --- |
| `@key` | Makes the type an entity: in `_Entity`, resolved by `_entities` (above). Repeatable; `resolvable: false` keys are kept, for the gateway. |
| `@external` | Its values in a representation are set on the record. |
| `@requires`, `@provides` | Passed through; the field resolves as any other. |
| `@shareable` | Passed through. Added to the types `@paginate` generates. |
| `@interfaceObject` | The type is an entity of its own in this subgraph. |
| `@override`, `@inaccessible`, `@tag`, `@extends` | Passed through. |
| `@composeDirective` | Passed through, with your directive's definition and link. |
| `@authenticated`, `@requiresScopes`, `@policy` | Passed through, for the router to enforce (`@policy` through its coprocessor or Rhai script); Lighthouse's own `@guard` and `@can*` still run in the subgraph. |
| `@context`, `@fromContext` | Passed through: the router fills the argument; the type that has the field must have a resolvable `@key`. |
| `@cost`, `@listSize` | Passed through, for the router's demand control. |

## Subscriptions

Apollo Router delivers a subgraph's subscriptions to its clients (over WebSocket
or multipart HTTP) and asks the subgraph for them through its
[HTTP callback protocol](https://www.apollographql.com/docs/graphos/routing/operations/subscriptions/callback-protocol).
Lighthouse speaks it as a graphql-ruby subscription backend:

```ruby
class AppSchema < Lighthouse::GraphQL::RbLightHouse.get_schema(options: { base_types: { ... } })
  use Lighthouse::GraphQL::Federation::CallbackSubscriptions
end
```

```yaml
# router.yaml
subscription:
  enabled: true
  mode:
    callback:
      public_url: http://router.internal:4000/callback
      listen: 0.0.0.0:4000
      path: /callback
      subgraphs: [blog]
```

The subscription fields, their classes and `@broadcast` are what
[subscriptions.md](subscriptions.md) describes; only the transport changes. The
router sends the subscription to the subgraph's endpoint with
`extensions.subscription` (its callback URL, an id, a verifier and the heartbeat
interval), which `Lighthouse::GraphQL::Controller` reads:

1. the subscription runs as any other (the class's `authorized?` / `authorize?`;
   an error goes back to the router, and to the client);
2. the backend sends the router a `check`, and keeps the subscription once the
   router answers it; the request answers `{ "data": null }`;
3. every update `@broadcast` (or `trigger`) causes runs the subscriber's
   operation again, in its context (`filter?` and `update` decide who gets it),
   and goes to the router as a `next` message; the router resolves the other
   subgraphs' fields of it;
4. a `check` is sent every heartbeat interval; a subscription the router answers
   404 for (its client left) is dropped; one that ends here (`unsubscribe`) is
   sent `complete`.

A subscription lives in the process that received it, as ActionCable's do. A
trigger from another process (a job, another Puma worker) reaches it through
Action Cable's pubsub when the app has Action Cable (its `cable.yml` adapter:
solid_cable, redis, postgresql); otherwise only the triggering process's
subscriptions are updated. If a process restarts, its subscriptions' heartbeats
stop, the router ends them, and their clients subscribe again.

`use ..., client:` takes another HTTP client (`post(url, body) -> status`), and
`tick:` how often, in seconds, due heartbeats are sent (1).

The backend is graphql-ruby's `ActionCableSubscriptions` as well: a
subscription without a callback, over
[Server-Sent Events](subscriptions.md#over-server-sent-events) or an Action
Cable channel, is kept as that backend keeps it, and one trigger reaches the
router's subscriptions, the SSE streams and the sockets alike. A gateway that
asks its subgraphs for subscriptions over SSE (GraphQL Yoga, Hive Gateway, any
on `@graphql-tools/executor-http`) needs nothing else; `examples/graphql-federations`
runs its suite through Apollo Router and through GraphQL Yoga, whose clients
subscribe over SSE too. A subscription
that came through none of them (no callback, no channel) is refused.

## Apollo Router and GraphOS

The router runs most of this unlicensed. Some of its features need a router
connected to GraphOS (`APOLLO_KEY` and `APOLLO_GRAPH_REF`; a free plan's graph
will do), and it refuses to start without one when its config or supergraph uses
them: subscriptions, batching (`batching:`), and the `@authenticated` and
`@requiresScopes` directives, among others (router 2.19 runs file uploads,
`@policy`, `@cost` and `@context` unlicensed). The example's suite starts the
router with them only when those variables are set.

## Migrating from `apollo-federation`

A graphql-ruby app federates code-first with the [`apollo-federation`](https://github.com/Gusto/apollo-federation-ruby)
gem: a mixin in each base class, and the federation directives declared in Ruby.
Lighthouse federates from the SDL, so they move there, and the mixins go. Lighthouse
refuses them (a `Lighthouse::DefinitionError` naming each class): the type mixins
would be silently ignored, and `ApolloFederation::Schema` would replace the
subgraph's SDL and `_entities` with the gem's, which link Federation 2.3 whatever
the SDL says and cannot resolve an entity interface.

| apollo-federation | Lighthouse |
| --- | --- |
| `include ApolloFederation::Schema`, `federation(version: '2.x')`, `query(superclass.query)` | `extend schema @link(url: "https://specs.apollo.dev/federation/v2.x", import: [...])` in the SDL |
| `include ApolloFederation::Object`; `key fields: :id` (`camelize:`, `resolvable: false`) | `type User @key(fields: "id")` (`resolvable: false` as written) |
| `extend_type`, `shareable`, `inaccessible`, `interface_object`, `tag name:` | `@extends`, `@shareable`, `@inaccessible`, `@interfaceObject`, `@tag(name:)` on the type |
| `include ApolloFederation::Field`; `external: true`, `requires: { fields: ... }`, `provides: { fields: ... }` | `@external`, `@requires(fields: "...")`, `@provides(fields: "...")` on the field |
| `shareable: true`, `inaccessible: true`, `override: { from: "x" }`, `tags: [{ name: "x" }]` | `@shareable`, `@inaccessible`, `@override(from: "x")`, `@tag(name: "x")` on the field |
| `include ApolloFederation::Interface`; `key fields:` | `interface Media @key(fields: "id")`, an entity interface (above) |
| `include ApolloFederation::Union`, `Enum`, `Scalar`, `InputObject`; `tag`, `inaccessible` | `@tag(name:)`, `@inaccessible` on the union, enum, scalar or input |
| `include ApolloFederation::EnumValue`, `Argument`; `tags:`, `inaccessible:` | `@tag(name:)`, `@inaccessible` on the enum value or argument |
| `def self.resolve_reference(reference, context)` on the type | The same, on its type class (`Types::UserType`); or nothing, when its model is found by its keys |
| `def self.resolve_references(references, context)` | The same |
| `use ApolloFederation::Tracing` | Unchanged: a plugin, not a mixin |

Two things work differently:

- **Field names in the SDL are camelCase already**: `@key(fields: "authorId")`, where
  `key fields: :author_id` was camelized for you. A representation reaches
  `resolve_reference` with the gateway's camelCase keys, read with strings or
  symbols alike (`representation[:authorId]`); `underscore_reference_keys` has no
  counterpart.
- **`Lighthouse::ReferenceResolver` is gone too**: move each registered block into
  its type class's `resolve_reference`.
