# Relay: Global Object Identification

Relay clients refetch any object by one opaque id, through a root `node` field.
Lighthouse gives a schema that, as [PHP Lighthouse](https://lighthouse-php.com/master/digging-deeper/relay.html)
does, with two directives: `@globalId` encodes and decodes the ids, and `@node`
makes a type findable by them. For Relay's cursor pagination, see
[`@paginate(type: CONNECTION)`](directives.md#paginate).

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

## Your own encoding

[`global_id`](configuration.md#global_id) takes any object with
`encode(type, id)` and `decode(global_id)`, which returns `[type, id]`:

```ruby
Lighthouse.configure do |config|
  config.global_id = MyGlobalIds   # e.g. signed, or a UUID lookup
end
```
