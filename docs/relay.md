# Relay: Global Object Identification

Relay clients refetch any object by one opaque id, through a root `node` field.
Lighthouse gives a schema that, as [PHP Lighthouse](https://lighthouse-php.com/master/digging-deeper/relay.html)
does, with two directives: `@globalId` encodes and decodes the ids, and `@node`
makes a type findable by them. For Relay's cursor pagination, see
[`@paginate(type: CONNECTION)`](directives.md#paginate).

An app whose schema has graphql-ruby's Relay, as `rails g graphql:install` writes it
by default, uses the same directives on graphql-ruby's ids and `Node`: see
[Relay through graphql-ruby](#relay-through-graphql-ruby). The sections before it
describe a schema without it.

## Global ids

`@globalId` on a field encodes its value with the type's name:

```graphql
type User {
  id: ID! @globalId
  name: String
}
```

`{ user(id: 1) { id } }` answers `"VXNlcjox"`, the base64 of `User:1`.

On an argument, or an input field, `@globalId` decodes what the client sent before
the field resolves, so every resolver (a directive, `@field`, a `Resolvers::` class)
gets the decoded value. `decode:` says which part:

| `decode:` | The resolver gets |
| --- | --- |
| `ARRAY` (default) | `["User", "1"]` |
| `TYPE` | `"User"` |
| `ID` | `"1"` |

```graphql
type Query {
  user(id: ID! @globalId(decode: ID) @eq): User @find
}

type Mutation {
  deleteNode(id: ID! @globalId): Node
}
```

Lists of ids decode item by item. A value that is not a global id makes the field
fail with `"…" is not a valid global id.`

## Nodes

`@node` registers a type for refetching:

```graphql
type User @node {
  id: ID! @globalId
  name: String
}
```

and adds what Relay expects, leaving alone whatever the SDL declares itself:

```graphql
"Any object implementing this type can be found by ID through `Query.node`."
interface Node {
  "Global identifier that can be used to resolve any Node implementation."
  id: ID!
}

type User implements Node @node { ... }

type Query {
  "Fetches an object given its globally unique `ID`."
  node(id: ID! @globalId): Node
}
```

```graphql
{
  node(id: "VXNlcjox") {
    id
    ... on User { name }
  }
}
```

The type keeps its own `id: ID! @globalId`, which encodes the ids `node` decodes.
`node` answers `null` for an id with no object, and an error for the id of a type
without `@node`.

### Where the object comes from

1. `@node(resolver: "Countries@by_code")` names a class, and a method after the `@`
   (`call` without one). It gets the decoded id and the context, and returns any
   object, a Hash included:

   ```graphql
   type Country @node(resolver: "Countries@by_code") {
     id: ID! @globalId
     name: String!
   }
   ```

   ```ruby
   class Resolvers::Countries
     COUNTRIES = { 'DE' => { id: 'DE', name: 'Germany' } }.freeze

     def self.by_code(id, _context) = COUNTRIES[id]
   end
   ```

   The class is looked up as `@field` looks one up on a type: in the resolvers
   namespace, then in [`resolver_namespaces`](configuration.md#resolver_namespaces).
2. `@node(model: "Account")` names the model.
3. Otherwise, the type's [`@model`](directives.md#model), or the model named
   after the type.

A model's record is found by its primary key, through graphql-ruby's Dataloader, so
several `node` fields in one query load together.

To give `Query.node` your own description or middleware, declare it, with the
registry Lighthouse uses:

```graphql
type Query {
  "This description is up to you."
  node(id: ID! @globalId): Node
    @field(resolver: "Lighthouse::GraphQL::NodeRegistry@resolve")
    @guard
}
```

## Relay through graphql-ruby

graphql-ruby's install (`--relay`, its default) writes Relay's side in Ruby:
`Types::NodeType`, the `node` and `nodes` fields of `Types::QueryType`, and the
schema's `id_from_object` / `object_from_id`, on Rails' GlobalID:

```ruby
class AppSchema < Lighthouse::GraphQL::RbLightHouse.get_schema(
  options: { base_types: { query_type: Types::QueryType, node: Types::NodeType, object: Types::BaseObject } }
)
  def self.id_from_object(object, type_definition, query_ctx)
    object.to_gid_param
  end

  def self.object_from_id(global_id, query_ctx)
    GlobalID.find(global_id)
  end
end
```

`lighthouse:install` names those classes in `base_types`, and Lighthouse's
directives then work on them. The schema has one kind of global id and one `Node`:

- `@globalId` on a field that resolves an object's own id encodes it with
  `id_from_object`: `Tag.id` answers `tag.to_gid_param`, as graphql-ruby's `Node.id`
  does. Any other value is encoded as before.
- `@globalId` on an argument decodes with `object_from_id`, which loads the object.
  `ID` gives its id, and `ARRAY` / `TYPE` its class name (`["Tag", 1]`, `"Tag"`).
- `node:` is the SDL's `Node` interface: `interface Node`, which `@node` adds, and
  `implements Node` refer to `Types::NodeType`. A `@node` type implements it.
- `Query.node` and `nodes` find objects with `object_from_id`, through the
  `#node` and `#nodes` methods of `Types::QueryType`. `lighthouse:install`
  declares both fields in the starter `graphql/schema.graphql`, and removes the
  `field :node` / `field :nodes` that graphql-ruby wrote in `Types::QueryType`,
  so the SDL is where they are declared. An SDL field without a resolving
  directive resolves with the root type class's method of its name. If the
  fields stay in `Types::QueryType` instead, they are part of the schema too, and
  the `node` field `@node` would add to `Query` gives way to them.

The starter schema `lighthouse:install` writes on graphql-ruby's Relay:

```graphql
type Query {
  "Fetches an object given its ID. Resolved by Types::QueryType#node, with AppSchema.object_from_id."
  node("ID of the object." id: ID!): Node

  "Fetches a list of objects given a list of IDs. Resolved by Types::QueryType#nodes."
  nodes("IDs of the objects." ids: [ID!]!): [Node]

  user(id: ID! @globalId(decode: ID) @eq): User @find
  users: [User!]! @paginate(defaultCount: 10)
}

interface Node {
  "ID of the object."
  id: ID!
}

type User @node {
  id: ID! @globalId
  name: String
  email: String
}
```

```ruby
module Types
  class QueryType < Types::BaseObject
    # Query.node and nodes are declared in graphql/schema.graphql; these methods resolve them.
    def node(id:)
      context.schema.object_from_id(id, context)
    end

    def nodes(ids:)
      ids.map { |id| context.schema.object_from_id(id, context) }
    end
  end
end
```

`lighthouse:install` writes this only when the app has no schema file yet, and
only on the `node` / `nodes` fields as graphql-ruby writes them.

```graphql
type Tag @node {
  id: ID! @globalId
  name: String!
}

type Query {
  tag(id: ID! @globalId(decode: ID) @eq): Tag @find
}
```

```graphql
{
  node(id: "Z2lkOi8vYXBwL1RhZy8x") { id ... on Tag { name } }
  tag(id: "Z2lkOi8vYXBwL1RhZy8x") { name }
}
```

`Tag.id` and both arguments carry `Tag` 1's GlobalID (`gid://app/Tag/1`, in base64).
`Query.node` finds every object with `object_from_id`, so `@node(resolver:)` and
`@node(model:)` play no part in it, and [`global_id`](configuration.md#global_id)
encodes only what `id_from_object` does not. A schema without `id_from_object` /
`object_from_id` works as the sections above describe.

## Your own encoding

[`global_id`](configuration.md#global_id) takes any object with
`encode(type, id)` and `decode(global_id)`, which returns `[type, id]`:

```ruby
Lighthouse.configure do |config|
  config.global_id = MyGlobalIds   # e.g. signed, or a UUID lookup
end
```
