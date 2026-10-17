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

It returns a plain list. The model defaults to the field's return type (`User`).
Override it with `@all(model: "Account")`, and narrow it with model scopes:
`@all(scopes: ["active"])`. Combine with
[argument filters](filtering-and-ordering.md) and [`@orderBy`](#orderby) to
constrain the result.

### `@find`

Return the single record the field's argument filters select. More than one match
is an error (`The query returned more than one result.`); none returns `null`.

```graphql
type Query {
  user(id: ID! @eq): User @find
  userByEmail(email: String! @eq): User @find
}
```

A lookup by `id` alone is batched through the Dataloader. An `id` argument without
a filter directive still selects by primary key. `scopes:` applies model scopes.

### `@first`

Like `@all`, but returns the **first** matching record instead of a list. Useful
with filters to fetch one record by criteria.

```graphql
type Query {
  latestPost(authorId: ID! @eq): Post @first(scopes: ["published"])
}
```

### `@paginate`

Return one page of a model's records. Lighthouse rewrites the field and adds the
pagination arguments, exactly as PHP Lighthouse does:

| `type:` | Arguments | Returns |
| --- | --- | --- |
| `PAGINATOR` (default) | `first: Int!`, `page: Int` | `PostPaginator! { paginatorInfo: PaginatorInfo!, data: [Post!]! }` |
| `SIMPLE` | `first: Int!`, `page: Int` | `PostSimplePaginator! { paginatorInfo: SimplePaginatorInfo!, data }`, with no total, so one query fewer |
| `CONNECTION` | `first: Int!`, `after: String` | `PostConnection! { pageInfo: PageInfo!, edges: [PostEdge!]! }`, Relay style |

```graphql
type Query {
  posts(title: String @like): [Post!]! @paginate(defaultCount: 20, maxCount: 100)
}
```

```graphql
{ posts(first: 10, page: 2) { paginatorInfo { total lastPage hasMorePages } data { title } } }
```

- **The query.** It is the model's (`model:`, else the return type), narrowed by
  `scopes:`, [`@builder`](#builder) and the field's argument filters. On a nested
  field it pages the parent's association of the same name: `User.posts @paginate`
  pages the user's posts.
- **`first`.** It defaults to `defaultCount`, else
  [`Config.pagination_default_count`](configuration.md#pagination_default_count--pagination_max_count).
  Without either, clients must pass it.
- **`maxCount`.** It caps `first`, overriding `Config.pagination_max_count`;
  `maxCount: null` means unlimited.
- **The total** is only counted when the client selects `paginatorInfo` or
  `pageInfo`.
- **Cursors** are base64 of the item's position.

### `@count`

Return the number of records — of a model, or of a relation on the parent object.

```graphql
type Query {
  userCount: Int! @count(model: "User")
  activeUserCount: Int! @count(model: "User", scopes: ["active"])
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
| `@hasMany` | one-to-many: a list, or paginated with `type:` |
| `@hasOne` | one-to-one |
| `@belongsTo` | inverse of has-one/has-many |
| `@belongsToMany` | many-to-many: a list, or paginated with `type:` |
| `@morphTo`, `@morphOne`, `@morphMany`, `@morphToMany` | the polymorphic variants |

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

Delegate a field to a class — your escape hatch for anything the built-in
directives don't cover. On `Query` and `Mutation` you usually don't need it:
a field without a resolving directive resolves to `Queries::<FieldName>` /
`Mutations::<FieldName>`, graphql-ruby resolver and mutation classes. See
[resolvers.md](resolvers.md).

```graphql
type Contact {
  person: Person @field(resolver: "Resolvers::ContactPerson")
}
```

On `Query` and `Mutation` the name is looked up in the queries / mutations
namespaces, elsewhere in [`resolver_namespaces`](configuration.md). The class may
be a `GraphQL::Schema::Resolver` (graphql-ruby's contract), or a plain callable —
a class-level `call`, an instance `#call`, or an instance `#resolve`, each
receiving `(object, args, context)`:

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
  me: User @guard
}
```

### `@canFind`, `@canModel`, `@canQuery`, `@canResolved`, `@canRoot`

Authorize a field with a policy ability (Pundit by default; configurable) — each
directive authorizes something different: the models an argument identifies, the
model class, the models the field's filters select, the resolved value, or the
parent object. All `repeatable`; shared arguments `ability`, `injectArgs`, `args`,
`action`, `returnValue`.

```graphql
type Mutation {
  createPost(input: CreatePostInput! @spread): Post @create @canModel(ability: "create")
  updatePost(id: ID!, title: String): Post @update @canFind(ability: "update", find: "id")
}
```

See [authorization.md](authorization.md). (`@can` was removed in favour of this
family — it has a migration table.)

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
  contacts: [Contact!]! @paginate @builder(class: "Unassigned")
}
```

Builders are looked up in their own namespace, `Builders::` (app/graphql/builders)
— they are not resolvers. See [resolvers.md](resolvers.md#builders).

```ruby
module Builders
  class Unassigned
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
| `@whereKey` | `primary key = value` (`IN` for a list) |
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

## Mutation directives

`@create`, `@createMany`, `@update`, `@updateMany`, `@upsert` and `@upsertMany`
save the model a field returns through ActiveRecord, with its validations, in a
transaction. Input on its associations runs as
[nested mutations](mutations.md#nested-mutations). `@delete` destroys the records
its filter arguments (`@whereKey`, `@eq`, …) select. `@spread` flattens an input
argument into the attributes, `@rename` maps an argument to another attribute,
and `@inject(context:, name:)` sets server-side attributes.

```graphql
type Mutation {
  createPost(input: CreatePostInput! @spread): Post!
    @create @inject(context: "current_user.id", name: "author_id")
  updatePost(id: ID!, title: String): Post! @update
}
```

See [mutations.md](mutations.md).

---

## Validation

`@validator` runs a contract (Dry::Validation by default) before a field
resolves — on a field, or on an input type wherever it is used. Model validations
need no directive. See [validation.md](validation.md).

```graphql
input CreateUserInput @validator { email: String password: String }
```

---

## Caching

`@cache(maxAge:, private:)` keeps a field's value in `Rails.cache`, keyed with the
help of `@cacheKey`; `@clearCache(type:, idSource:, field:)` invalidates it from a
mutation. `@cacheControl(maxAge:, scope:, inheritMaxAge:)` computes the response's
HTTP `Cache-Control` header. See [caching.md](caching.md).

```graphql
type Query {
  temperature: Int! @cache(maxAge: 300) @cacheControl(maxAge: 300)
}
```

---

## Adding your own

Every directive above is a small class registered with
`Lighthouse::DirectiveRegistry`. To add one, implement the relevant
[contract](custom-directives.md) and register it — no edits to Lighthouse
internals. See [custom-directives.md](custom-directives.md).
