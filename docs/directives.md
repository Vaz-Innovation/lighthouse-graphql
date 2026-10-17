# Directives Reference

Directives are how you add behavior to your schema. They begin with `@` and are
attached to fields or arguments. Lighthouse **contributes the SDL definitions for
its own directives automatically**, so you don't have to declare
`directive @all(...) on ...` yourself — just use them.

Below is every built-in directive, grouped by purpose. Federation directives are
documented separately in [federation.md](federation.md).

---

## Query / fetch directives

These resolve a root (or any) field from a model.

### `@all`

Return all records of a model.

```graphql
type Query {
  users: [User!]! @all
}
```

The model defaults to the field's return type (`User`). Override with
`@all(model: "Account")`. Combine with [argument filters](filtering-and-ordering.md)
and [`@orderBy`](#orderby) to constrain the result.

### `@find`

Return a single record, typically by id. Pair it with an argument filter such as
[`@eq`](#eq) so Lighthouse knows what to match on.

```graphql
type Query {
  user(id: ID! @eq): User @find
}
```

### `@first`

Like `@all`, but returns the **first** matching record instead of a list. Useful
with filters to fetch one record by criteria.

```graphql
type Query {
  latestPost(authorId: ID! @eq): Post @first
}
```

### `@paginate`

Return a paginated list. Lighthouse rewrites the field to a Paginator type and
adds pagination arguments.

```graphql
type Query {
  posts: [Post!]! @paginate
}
```

becomes, in effect:

```graphql
type Query {
  posts(first: Int, after: String): PostConnection
}
```

Use `@paginate(type: "CONNECTION")` for Relay-style cursor connections, or the
default offset-based paginator otherwise.

### `@count`

Return the number of records — of a model, or of a relation on the parent object.

```graphql
type Query {
  userCount: Int! @count(model: "User")
}

type Account {
  usersCount: Int! @count(relation: "users")
}
```

### `@aggregate`

Compute an aggregate (`SUM`, `AVG`, `MIN`, `MAX`, `COUNT`) over a column.

```graphql
type Account {
  totalRevenue: Float @aggregate(relation: "orders", column: "amount", function: "SUM")
}
```

---

## Relationship directives

Resolve ActiveRecord associations, batched through a Dataloader to avoid N+1.
See [relationships.md](relationships.md) for the full guide.

| Directive | Association |
| --- | --- |
| `@hasMany` | one-to-many (returns a connection) |
| `@hasOne` | one-to-one |
| `@belongsTo` | inverse of has-one/has-many |
| `@belongsToMany` | many-to-many |

```graphql
type User {
  posts: [Post!]! @hasMany
  profile: Profile @hasOne
  account: Account! @belongsTo
  roles: [Role!]! @belongsToMany
}
```

The relation name defaults to the field name (snake_cased). Override with
`@hasMany(relation: "authored_posts")`.

---

## Field directives

### `@field`

Delegate a field to a custom resolver class — your escape hatch for anything the
built-in directives don't cover.

```graphql
type Contact {
  person: Person @field(resolver: "Resolvers::ContactPerson")
}
```

The resolver is resolved against your configured
[`resolver_namespaces`](configuration.md). It may be a class with a class-level
`call`, an instance `#call`, or an instance `#resolve`, each receiving
`(object, args, context)`:

```ruby
module Resolvers
  class ContactPerson
    def call(contact, _args, _ctx)
      contact.linked_person
    end
  end
end
```

### `@rename`

Read a differently-named attribute off the parent object. This is the explicit
override of the default camelCase→snake_case reader.

```graphql
type User {
  displayName: String @rename(attribute: "full_name")
}
```

### `@method`

Resolve a field by calling a method on the parent object (PHP-parity). Great for
exposing a computed method or predicate without a custom resolver.

```graphql
type Conversation {
  labels: [String!]! @method(name: "label_list")
  canReply: Boolean @method(name: "can_reply?")
}
```

---

## Authentication & Authorization

Enforce auth declaratively instead of in resolvers. Full guide:
[authorization.md](authorization.md).

### `@guard`

Require an authenticated user before the field resolves; otherwise raise
`Unauthenticated.`. Runs outermost.

```graphql
type Query {
  me: User @field(resolver: "Resolvers::CurrentUser") @guard
}
```

### `@can`

Authorize a field with a policy ability (Pundit by default; configurable). By
default it authorizes the resolved record. `repeatable`.

```graphql
type Query {
  contact(id: ID!): Contact
    @field(resolver: "Resolvers::ContactResolver")
    @can(ability: "show")
}
```

`@can(ability:, find:, model:, root:)` — see [authorization.md](authorization.md)
for the `find`/`model`/`root` modes.

### `@auth`

The original guard directive — require an authenticated user
(`context[:current_user]`) before the field resolves; otherwise raise
`Unauthenticated.`. `@guard` is the preferred, configurable equivalent.

```graphql
type Query {
  me: User @auth
}
```

---

## Query builder customization

### `@builder`

Apply a custom method to the query builder before the field resolves. Repeatable.

```graphql
type Query {
  contacts: [Contact!]! @paginate @builder(class: "Resolvers::ContactsBuilder")
}
```

```ruby
module Resolvers
  class ContactsBuilder
    def self.call(relation, args, _ctx)
      args[:unassigned] ? relation.left_joins(:assignments).where(assignments: { id: nil }) : relation
    end
  end
end
```

---

## Argument filters

Attach these to a **field argument** to compose a `WHERE`/`ORDER BY` clause onto
the query when the client supplies that argument. They compose in argument order.
Full guide: [filtering-and-ordering.md](filtering-and-ordering.md).

| Directive | Effect |
| --- | --- |
| `@eq` | `column = value` |
| `@neq` | `column != value` |
| `@in` | `column IN (values)` |
| `@notIn` | `column NOT IN (values)` |
| `@like` | `column LIKE %value%` |
| `@where(operator:)` | generic operator (`GT`, `GTE`, `IN`, `IS_NULL`, `CONTAINS`, …) |
| `@orderBy` | sort by one or more columns |

```graphql
type Query {
  users(
    status: String @eq
    nameSearch: String @like
    minAge: Int @where(operator: "GTE", key: "age")
    orderBy: [OrderByClause!] @orderBy
  ): [User!]! @all
}
```

The column defaults to the snake_cased argument name; override with `key:`.

### `@whereConditions` / `@whereHasConditions`

Give clients a structured, dynamic `WHERE` builder (AND/OR/operators, and HAS for
related records). Lighthouse generates the input and enum types for you. See
[filtering-and-ordering.md](filtering-and-ordering.md#complex-where-conditions).

```graphql
type Query {
  people(where: _ @whereConditions(columns: ["age", "type"])): [Person!]! @all
}
```

---

## Adding your own

Every directive above is a small class registered with
`Lighthouse::DirectiveRegistry`. To add one, implement the relevant
[contract](custom-directives.md) and register it — no edits to Lighthouse
internals. See [custom-directives.md](custom-directives.md).
