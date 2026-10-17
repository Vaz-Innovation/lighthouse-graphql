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

### `@convertEmptyStringsToNull`

Replaces incoming empty strings `""` with `null`, before any resolver sees them —
directive resolvers (`@create`, `@all` filters, …), `@field`, `Queries::` /
`Mutations::` classes and `@validator` alike. On an argument or an input field it
converts that one input; on a field it converts every input of the field, nested
input objects and lists included. Non-null inputs (`String!`) pass unchanged when
the directive is only on the field: placing it on the non-null argument or input
field itself forces the conversion.

```graphql
type Mutation {
  createPost(title: String @convertEmptyStringsToNull, body: String): Post! @create
  signUp(input: SignUpInput!): User! @create @convertEmptyStringsToNull
}

input SignUpInput {
  name: String          # "" becomes null on signUp, but not where no directive applies
  nickname: String @convertEmptyStringsToNull   # on every field taking SignUpInput
  email: String!        # unchanged; add the directive here to force it
}
```

A directive on an input field applies wherever the input type is used; one on a
field affects only that field. To enable it for every field, set
[`convert_empty_strings_to_null`](configuration.md#convert_empty_strings_to_null).

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

## Soft deletes & global scopes

Rails has no built-in soft deletes or named global scopes, so these directives
work with what Rails apps use. Lighthouse detects, per model, in this order:

1. **[paranoia](https://github.com/rubysherpas/paranoia)** (`acts_as_paranoid`):
   a default scope hides trashed records.
2. **[discard](https://github.com/jhawthorn/discard)** (`include Discard::Model`):
   nothing is hidden, unless the model adds `default_scope -> { kept }`.
3. **A plain `deleted_at` column**, with no gem (a default scope is optional).

An app with its own scheme, or another column, sets
[`Config.soft_deletes`](configuration.md#soft_deletes). A model that matches none
of them is an error when a client uses one of these directives on it
(`Model Widget does not support soft deletes …`).

### `@softDeletes`

Lets clients filter trashed records. It adds the argument
`trashed: Trashed @trashed` to the field and defines the `Trashed` enum once
(unless your schema declares its own).

```graphql
type Query {
  tasks: [Task!]! @all @softDeletes
}
```

becomes

```graphql
type Query {
  tasks(trashed: Trashed @trashed): [Task!]! @all
}

"Specify if you want to include or exclude trashed results from a query."
enum Trashed {
  "Only return trashed results."
  ONLY
  "Return both trashed and non-trashed results."
  WITH
  "Only return non-trashed results."
  WITHOUT
}
```

### `@trashed`

The argument builder `@softDeletes` adds; use it by hand to name the argument
yourself. It works wherever argument filters do: `@all`, `@paginate`, `@find`,
`@first`, `@count` and the relationship directives (`@hasMany`, …, including
paginated ones, which keep batching through the Dataloader).

```graphql
type Query {
  flights(trashed: Trashed @trashed, destination: String @eq): [Flight!]! @all
}
type Post {
  comments(trashed: Trashed @trashed): [Comment!]! @hasMany
}
```

| Value | Result |
| --- | --- |
| `ONLY` | only trashed records |
| `WITH` | trashed and non-trashed records |
| `WITHOUT` | only non-trashed records |
| *(omitted)* | **the model's own behaviour, untouched**: paranoia and a default scope hide trashed records, a bare `deleted_at` column or discard without a default scope show everything |

`ONLY`, `WITH` and `WITHOUT` lift the model's default scope on the soft-delete
column first, so they behave the same whatever the model does by default. That
is `unscope(where: column)`, which removes every condition on that column from
the query, including one added by an argument declared before `trashed`. Avoid a
separate filter on the soft-delete column itself.

### `@forceDelete`

Permanently removes one or more soft deleted models. It works like
[`@delete`](mutations.md#delete): the filter arguments (`@whereKey`, `@eq`, …) are
required (`Would modify all models, use an argument to filter.`), the removed
models are returned (a list for a list field, else the first or `null`), and
`model:` and `scopes:` are honoured. It finds trashed models even when the model
hides them by default, and it removes live ones too. It runs in a transaction
(`Config.transactional_mutations`).

```graphql
type Mutation {
  forceDeletePost(id: ID! @whereKey): Post @forceDelete
  forceDeletePosts(ids: [ID!]! @whereKey): [Post!]! @forceDelete
}
```

paranoia models are removed with `really_destroy!`, discard and `deleted_at`
models with `destroy`. A model whose callbacks refuse is reported as
`Could not modify model Post with ID 1.`

### `@restore`

Un-deletes one or more soft deleted models, with the same arguments, guard and
result as `@forceDelete`: paranoia's `restore`, discard's `undiscard`, or setting
the `deleted_at` column to `NULL`.

```graphql
type Mutation {
  restorePost(id: ID! @whereKey): Post @restore
}
```

### `@withoutGlobalScopes`

Omits global scopes from the query when the client passes `true`. Use it on a
`Boolean` argument; `false` and an omitted argument leave the scopes in place.

```graphql
type Query {
  posts(includeUnscheduled: Boolean @withoutGlobalScopes(names: ["scheduled"])): [Post!]! @all
}
```

ActiveRecord has one anonymous `default_scope`, not scopes with names, so each
name is resolved like this (snake_cased; a trailing `Scope` is optional):

1. A model scope **`without_<name>`**, if the model has one. You write it:
   `scope :without_scheduled, -> { unscope(where: :schedule_at) }`.
2. Else a **column** of that name: `unscope(where: column)`. Like `@trashed`, this
   removes every condition on that column from the query, including ones added by
   earlier arguments.
3. Else a soft-delete name (`softDeletes`, `SoftDeletingScope`): trashed records
   are included, as with `trashed: WITH`.

Any other name is an error: `Cannot omit the global scope …`.

---

## Subscriptions

Fields of the `Subscription` type resolve to a `Subscriptions::` class by
convention, like queries and mutations, on top of graphql-ruby's subscriptions;
`@subscription` names another one, and `@broadcast` triggers a subscription from
a mutation. The backend (ActionCable, ...) is the schema's; see
[subscriptions.md](subscriptions.md).

### `@subscription`

```graphql
directive @subscription(class: String!) on FIELD_DEFINITION
```

Names the class a `Subscription` field resolves to, when it does not follow the
convention (`postUpdated` → `Subscriptions::PostUpdated`). The class inherits from
`Lighthouse::GraphQL::Subscription` (or `GraphQL::Schema::Subscription`) and is
looked up in `Config.namespaces[:subscriptions]`; a name with `::` is used as it
is.

```graphql
type Subscription {
  postUpdated(author: ID!): Post @subscription(class: "Blog::PostUpdatedSubscription")
}
```

### `@broadcast`

```graphql
directive @broadcast(subscription: String!, shouldQueue: Boolean) repeatable on FIELD_DEFINITION
```

Once the field has resolved, triggers the `subscription` field of the
`Subscription` type with the result as its root, so its subscribers are updated,
each passing through the class's `filter?`. A failed mutation, or a `nil` result,
broadcasts nothing. An unknown subscription name is a
`Lighthouse::DefinitionError` when the schema is built. `shouldQueue` performs the
trigger in an ActiveJob; without it, `Config.queue_broadcasts` (default `false`)
decides.

```graphql
type Mutation {
  createPost(input: CreatePostInput! @spread): Post! @create @broadcast(subscription: "postCreated")
  updatePost(input: UpdatePostInput! @spread): Post!
    @update
    @broadcast(subscription: "postUpdated", shouldQueue: false)
    @broadcast(subscription: "postChanged")
}
```

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

## Feature flags

### `@feature`

Include a field or an object type in the schema depending on a feature flag,
backed by [Flipper](https://www.flippercloud.io/docs) (PHP Lighthouse's
`@feature` is backed by Laravel Pennant).

```graphql
type Query {
  newCheckout: Checkout @feature(name: "new_checkout")
  legacyCheckout: Checkout @feature(name: "new_checkout", when: INACTIVE)
}

type Beta @feature(name: "beta") {
  id: ID!
}
```

| Argument | Meaning |
| --- | --- |
| `name: String!` | The feature to check. |
| `when: FeatureState! = ACTIVE` | The state the feature must be in for the element to be included: `ACTIVE` or `INACTIVE`. |

Feature flags depend on who asks, while the schema is built once, so the element
stays in the schema and is hidden **per query**, through graphql-ruby's
[visibility](https://graphql-ruby.org/authorization/visibility.html). A hidden
field or type disappears from introspection, and a query selecting it fails
validation (`Field 'newCheckout' doesn't exist on type 'Query'`). The fields
returning a hidden type are hidden with it. `to_definition` prints the schema as
the features stand for no actor.

Each feature is checked at most once per query. By default Flipper is asked
whether the feature is enabled for the authenticated user (`Flipper.enabled?(:new_checkout, user)`;
the user answers `flipper_id`, which Flipper's ActiveRecord integration adds to
models); with no user, the global gate decides. Flipper is optional: add
`gem "flipper"` to your Gemfile, or configure your own check with
`feature_checker` and `feature_actor` (see [configuration.md](configuration.md#feature_checker-feature_actor)).

```ruby
Flipper.enable_actor(:new_checkout, User.find(1))

# schema.execute(query, context: { current_user: user })
```

---

## Events

`@event` dispatches an event once the field has resolved. The class is built with
the resolved value and handed to `Lighthouse::Events.dispatch`; the value is
returned unchanged, and nothing is dispatched when the field raises. It is
repeatable: each `@event` dispatches its own. See [events.md](events.md) for
listening, and for the events Lighthouse itself dispatches.

```graphql
directive @event(dispatch: String!) repeatable on FIELD_DEFINITION
```

```graphql
type Mutation {
  shipOrder(id: ID!): Order!
    @update
    @event(dispatch: "OrderShipped")
    @event(dispatch: "Billing::InvoiceDue")
}
```

```ruby
class OrderShipped
  attr_reader :order

  def initialize(order) = @order = order
end

Lighthouse::Events.listen(OrderShipped) { |event| Mailer.shipped(event.order).deliver_later }
```

The class is looked up in `Config.namespaces[:events]` (default `['Events']`,
so `Events::OrderShipped`, then `::OrderShipped`); a name with `::` is used
as-is. A name that finds no class fails the schema build with
`Lighthouse::DefinitionError`. `@event` runs inside `@guard`, `@can*`,
`@validator` and `@cache`: a rejected request, or a cache hit, dispatches
nothing. (`@canResolved` checks the resolved value, so there the event is
dispatched before the check.)

---

## Adding your own

Every directive above is a small class registered with
`Lighthouse::DirectiveRegistry`. To add one, implement the relevant
[contract](custom-directives.md) and register it — no edits to Lighthouse
internals. See [custom-directives.md](custom-directives.md).
