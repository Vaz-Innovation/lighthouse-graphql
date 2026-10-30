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
  `scopes:`, the field's argument filters and [`@builder`](#builder). On a nested
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
- **The order** ends with the primary key: a page is cut by position, so rows the
  field's order ties (`@orderBy(column: "created_at")` on posts created in the same
  second), or a query with no order, would otherwise come back in another order on
  the next page, and a row would show on two pages or none. An order that names
  the key already, or a grouped query, is left as it is. PHP Lighthouse does not add it.

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
| `@hasManyThrough`, `@hasOneThrough` | PHP Lighthouse's names for `@hasMany` / `@hasOne` on a `has_many` / `has_one :through` |

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

### `@with`, `@withCount` and `@lazyLoad`

Eager loading for fields the relationship directives do not resolve, each across
every parent in the response at once. See
[relationships.md](relationships.md#eager-loading-for-other-fields).

```graphql
type User {
  "@with loads the relation before the field resolves, for a method that reads it."
  taskSummary: String! @with(relation: "tasks") @method(name: "task_summary")

  "@withCount sets posts_count on the user; the field's resolver reads it."
  activity: String! @withCount(relation: "posts", scopes: ["published"]) @method

  "@lazyLoad loads relations of the records the field returns."
  posts: [Post!]! @hasMany @lazyLoad(relations: ["tags", "comments.author"])
}
```

`relation` / `relations` may be nested with dots. `scopes` narrow the loaded or
counted records. `@with`'s `relation` defaults to the field's name.

---

## Field directives

### `@field`

Delegate a field to a class — your escape hatch for anything the built-in
directives don't cover. On `Query` and `Mutation` you usually don't need it:
a field without a resolving directive resolves to `Resolvers::<FieldName>` /
`Mutations::<FieldName>`, graphql-ruby resolver and mutation classes under
`Resolvers::BaseResolver` / `Mutations::BaseMutation`. See
[resolvers.md](resolvers.md).

```graphql
type Contact {
  person: Person @field(resolver: "Resolvers::ContactPerson")
}
```

On `Query` and `Mutation` the name is looked up in the queries / mutations
namespaces, a nested name too (`Feeds::Home` is `Resolvers::Feeds::Home`), and
then as written. On any other type it is looked up in the resolvers namespace the
same way (`Posts::TagsCount` is `Resolvers::Posts::TagsCount`), then in
[`resolver_namespaces`](configuration.md). There, the class's `object` is the parent: the
record the field belongs to (see
[resolvers.md](resolvers.md#fields-of-other-types)). The class may
be a `GraphQL::Schema::Resolver` (graphql-ruby's contract), or a plain callable —
a class-level `call`, an instance `#call`, or an instance `#resolve`, each
receiving `(object, args, context)`, and the [`ResolveInfo`](resolvers.md#resolveinfo)
as a fourth argument when it takes one:

```ruby
module Resolvers
  class ContactPerson
    def call(contact, _args, _ctx)
      contact.linked_person
    end
  end
end
```

A method after `@` replaces `call`, as PHP Lighthouse's `Class@method`: it is called
on the class when the class has it, else on an instance. On a
`GraphQL::Schema::Resolver` it replaces `resolve`, and `ready?` / `authorized?`
still run.

```graphql
type Query {
  usersTotal: Int @field(resolver: "Statistics@users_total")   # Resolvers::Statistics.users_total
}
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
exposing a computed method or predicate without a custom resolver. `name:`
defaults to the field's snake_case name.

```graphql
type Conversation {
  labels: [String!]! @method(name: "label_list")
  canReply: Boolean @method(name: "can_reply?")
  summary(words: Int = 20): String! @method
}
```

The field's arguments reach the method: as snake_case keywords when it takes
keywords (`def summary(words:)`), otherwise positionally, in the order the SDL
declares them, as PHP Lighthouse passes them (`def summary(words)`). The SDL's
defaults apply, and a method taking no parameters is called without them.

### `@attachment`

The URL of an ActiveStorage attachment of the parent, or the URLs of a
`has_many_attached`: the read side of [`@upload`](uploads.md). Lighthouse's own, as
Laravel has no ActiveStorage.

```graphql
type User {
  avatarUrl: String @attachment                                   # has_one_attached :avatar
  avatarThumbUrl: String @attachment(name: "avatar", variant: "thumb")
  photoUrls: [String!]! @attachment(url: PROXY)                   # has_many_attached :photos
}
```

- **`name`** defaults to the field's name without its `Url` / `Urls` suffix:
  `avatarUrl` reads `avatar`, `photoUrls` reads `photos`. A missing attachment is
  `null`, a model without one of that name an error.
- **Every parent's attachments and blobs load at once**, two queries for any
  number of users (`avatar_attachment: :blob`, what `User.with_attached_avatar`
  loads), through the Dataloader when the schema uses it.
- **`url`**: `REDIRECT` (default) is Rails' redirect to the storage service,
  `PROXY` streams the file through the app, and `DIRECT` is the service's own URL,
  signed for `expiresIn` seconds on a private one (`ActiveStorage.service_urls_expire_in`
  by default). The URL is absolute with the request's host, else a path.
- **`variant`** names a variant of the attachment
  (`has_one_attached :avatar { |attachable| attachable.variant :thumb, resize_to_limit: [100, 100] }`).
  A file that is not an image has none: `null`. A `REDIRECT` or `PROXY` variant is
  processed when its URL is first followed; `DIRECT` processes it while resolving.

## Relay

### `@globalId` and `@node`

`@globalId` encodes a field's value as a Relay global id (base64 of `Type:id`), and
decodes an argument or input field (`decode: ARRAY | TYPE | ID`). A decoded id must be
of the type it is for: `type:` names it, and with `decode: ID` an argument filtering
the field's model by its key is checked against that model, so another type's id
fails the field ([relay.md](relay.md#the-type-of-a-decoded-id)). `@node` on a type
makes it implement `Node` and adds `Query.node(id:)`, which finds the type's model
record, or calls `@node(resolver:)`. See [relay.md](relay.md).

```graphql
type User @node {
  id: ID! @globalId
}

type Query {
  user(id: ID! @globalId(decode: ID) @eq): User @find
}
```

## Execution

### `@namespaced`

A field that only groups others: it resolves to `true`, and the fields of its type
resolve with their own directives. On `Query` or `Mutation`.

```graphql
type Query { post: PostQueries! @namespaced }
type PostQueries {
  find(id: ID! @eq): Post @find
  list: [Post!]! @paginate
}
```

### `@throttle`

Rails' `rate_limit` on one field: at most `maxAttempts` calls (its `to:`) every
`decayMinutes` (its `within:`, default 60 a minute), counted before anything else runs.
It takes `rate_limit`'s options, and counts as `rate_limit` does: in the controller's
`cache_store`, under the same key, and instrumented as `rate_limit.action_controller`.
See [security.md](security.md#rate-limiting).

| Argument | `rate_limit`'s | Default |
| --- | --- | --- |
| `by:` | `by:`, who the client is: a path in the context, as [`@inject`](resolvers.md#spread-and-inject)'s (`"current_user.id"`) | the client's IP |
| `with:` | `with:`, the controller's method to call past the limit | `rate_limit`'s: a 429 (it raises `ActionController::TooManyRequests`) |
| `name:` | `name:`; fields, and the controller's own `rate_limit`, of the same name count together | the field (`Query.x`) |
| `prefix:` | `scope:` | the controller's path |

```graphql
type Mutation {
  login(email: String!, password: String!): User @throttle(maxAttempts: 5)
  createTag(name: String!): Tag! @throttle(maxAttempts: 20, by: "current_user.id", with: "too_many_requests") @guard @create
}
```

### `@async`

Runs a mutation in a job and answers `true` at once. `@guard`, the `@can*` family,
`@validator` and the argument directives run in the request, so the client still
gets their errors; what resolves the field runs in
`Lighthouse::GraphQL::AsyncMutationJob` (ActiveJob), with the arguments and the
context values ActiveJob can serialize (records too, through GlobalID). The field
must be a `Mutation` field returning `Boolean`, and the schema a named constant.

```graphql
type Mutation {
  importFeed(url: String!): Boolean! @guard @async(queue: "imports")
}
```

### `@hide` and `@show`

Leave a field out of the schema by environment (`Rails.env`): `@hide(env:)` removes
it in the environments listed, `@show(env:)` keeps it only in those.

```graphql
type Query {
  debugInfo: String @show(env: ["development", "test"])
  legacyFeed: [Post!]! @hide(env: ["production"]) @all
}
```

## Type directives

### `@model`

Maps an object type to the ActiveRecord model whose records it resolves, when the
names differ, as PHP Lighthouse's. Every directive that takes `model:` (`@all`,
`@find`, `@first`, `@paginate`, `@create`, `@update`, `@upsert`, `@delete`, the
`@can*` family...) on a field returning the type gets it, unless it names its own; a
union or interface resolves the model's records to the type; `@node` finds them. The
schema does not build unless the class is an ActiveRecord model.

```graphql
type Article @model(class: "Post") { id: ID! title: String! }

type Query {
  articles: [Article!]! @paginate          # pages through Post
  article(id: ID! @eq): Article @find
}
```

### `@enum`

The internal value of an enum value: what a resolver gets for it in an argument,
and what a result answers with it for.

```graphql
enum Role {
  ADMIN @enum(value: "admin")
  MEMBER @enum(value: "member")
}

type Query { users(role: Role @eq): [User!]! @all }   # filters on "admin"
```

They go on a union, an interface or a scalar, and name the class that resolves or
coerces its values. Without them, Lighthouse uses the type's class
(`Types::<Name>Type` including `Lighthouse::GraphQL::Type`), or its default. See
[types.md](types.md).

### `@union` and `@interface`

Name the class that picks the object type of each value: `resolve_type(object,
context)` or `call(object, context)`, returning a type name or a type class.
Looked up in the types namespace (nested names too), then as written.

```graphql
union SearchResult @union(resolveType: "SearchResultResolver") = Post | User
interface Authored @interface(resolveType: "AuthoredResolver") { id: ID! }
```

### `@scalar`

Names the class that reads and writes the scalar's values: `coerce_input(value,
context)` and `coerce_result(value, context)`, as a `GraphQL::Schema::Scalar`.

```graphql
scalar DateTime @scalar(class: "Types::DateTimeType")
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
— they are not resolvers. See [resolvers.md](resolvers.md#builders). The class is
`class:` with `method:` (default `call`), or PHP Lighthouse's `method: "Class@method"`.

On a field, the method gets `(relation, args, context)`, or the directive's
`value:` in place of the arguments. As in PHP Lighthouse, a field's `@builder`
(with `@whereAuth` and `@orderBy(column:)`) applies after the argument
directives, in SDL order. An `order` it adds therefore breaks the ties of the
client's `orderBy`. It applies on every field that queries records: `@all`,
`@paginate`, `@find`, `@first`, `@count`, `@aggregate`, the relationship
directives and `resolve_info.enhance_builder`. On an argument or an input field, it gets
`(relation, value, context)` whenever the client sends that argument, an explicit
`null` included, and not when it is left out:

```graphql
type Query {
  posts(since: DateTime @builder(method: "Recent@since")): [Post!]! @all
  latest: [Post!]! @all @builder(class: "Recent", value: 5)
}
```

```ruby
class Builders::Recent
  def self.call(relation, count, _context) = relation.order(created_at: :desc).limit(count)
  def self.since(relation, time, _context) = time ? relation.where(created_at: time..) : relation
end
```

### `@whereAuth`

Keep only the records the signed-in user owns, through a relation of the model: a
`belongs_to`, a `has_many`, a `:through`. A guest gets none. It applies where
`@builder` does (`@all`, `@paginate`, `@first`, `@count`, `enhance_builder`).

```graphql
type Query {
  myPosts: [Post!]! @paginate @whereAuth(relation: "author")
  myTeams: [Team!]! @all @whereAuth(relation: "members")
}
```

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
| `@whereNull` / `@whereNotNull` | `true`: `column IS NULL` / `IS NOT NULL`; `false`: the opposite |
| `@whereBetween` / `@whereNotBetween` | `column BETWEEN` / `NOT BETWEEN` the input's two fields, in order |
| `@whereJsonContains` | a JSON column contains the value (every value of a list); `key: "meta->tags"` points into it |
| `@scope(name:)` | calls the model scope with the value (`name:` defaults to the argument's) |
| [`@search(within:)`](#search) | runs the field's query through a full-text engine (Searchkick, pg_search) |
| `@orderBy` | sort by the client's clauses (columns, relations' aggregates); on a field, a fixed order |

```graphql
type Query {
  users(
    status: String @eq
    nameSearch: String @like
    minAge: Int @where(operator: "GTE", key: "age")
    orderBy: _ @orderBy(columns: ["name", "created_at"])
  ): [User!]! @all
}
```

The column defaults to the snake_cased argument name; override with `key:`.

```graphql
type Query {
  posts(
    unpublished: Boolean @whereNull(key: "published_at")
    createdAt: DateRange @whereBetween(key: "created_at")
    tagged: [String!] @whereJsonContains(key: "tags")
    trending: Boolean @scope
    filter: PostFilter
    limit: Int @limit
  ): [Post!]! @all
}

input DateRange { from: DateTime! to: DateTime! }
input PostFilter { title: String @like, authorId: ID @eq(key: "author_id") }
```

The filters on an input object's fields (`filter: PostFilter` above) apply when
the client sends it, at any depth and for each input of a list, as PHP
Lighthouse applies them. Those of a list's inputs all apply together.

### `@nest`

Accepted as PHP Lighthouse's SDL writes it, on an argument or input field of an
input object type. Filters on nested input fields apply without it.

### `@limit`

On an `Int` argument, caps how many results the field returns at the client's
value; `null` leaves them alone. A query not run yet gets a `LIMIT`; the records of
a relation, loaded for every parent at once, are cut per parent. A negative value is
an error.

`@limit(builder: true)` puts the `LIMIT` on the field's query instead, with the
other argument directives. Use it on root fields: on a relation batched for many
parents it would cut them all together, as PHP Lighthouse warns. PHP Lighthouse
also allows `@limit` on the field itself, where it only marks the field the argument
limits; it is accepted there and changes nothing.

### `@search`

Perform a full-text search by the given input value, as PHP Lighthouse's `@search`
does through Laravel Scout. On a `String` argument or input field:

```graphql
type Query {
  posts(search: String @search, authorId: ID @eq(key: "author_id")): [Post!]! @paginate
}
```

When the client sends a string (`""` too), the field's query runs through the engine
instead of the database. `null` or an omitted argument falls back to the database
query, so `posts(first: 10)` still lists. (`@convertEmptyStringsToNull` turns `""` into
`null`, so it does not search.)

```graphql
directive @search(
  "Specify a custom index to use for search."
  within: String
) on ARGUMENT_DEFINITION | INPUT_FIELD_DEFINITION
```

`within:` names the Searchkick index (`index_name:`), or the `pg_search_scope` to
search with (`search` by default); on a model that uses both gems, naming one of its
pg_search scopes searches with pg_search. It must be a string, or the schema fails to build.

Ruby has no Laravel Scout, so two gems back it, **neither a dependency of Lighthouse**: add
the one your models use to your Gemfile. The engine is detected per model
([`Config.search`](configuration.md#search) replaces the detection):

| Model | Engine | Runs |
| --- | --- | --- |
| calls `searchkick` | [Searchkick](https://github.com/ankane/searchkick) | in Elasticsearch / OpenSearch, outside the database |
| includes `PgSearch::Model` | [pg_search](https://github.com/Casecommons/pg_search) | in PostgreSQL, as a scope on the relation |

The two behave differently, and so do the directives next to `@search`; the
[full guide](filtering-and-ordering.md#full-text-search) has the details, and how to set
each engine up.

- **pg_search** narrows the relation, ranked first, and **everything else applies on
  top of it**: `scopes:`, `@builder`, `@whereAuth`, every argument filter, `@orderBy`,
  pagination, nested fields, batched as usual, and mass mutations (`@delete`, ...), where a
  `@search` argument counts as a filter only when the search runs. The primary key ends the
  order, after the orders that break the rank's ties.
- **Searchkick** answers with the records the engine found, in relevance order. Only `@eq`,
  `@trashed` and `@builder` on an argument narrow it (as Scout's `@eq` / `@trashed` /
  `@builder`); they work at any depth of input objects. It serves `@all`, `@paginate` of the
  model's whole table, and a resolver of your own (`resolve_info.enhance_builder` answers a
  `Lighthouse::Search::Result`, for the model's own relation only), with an exact total, within the index's result window (read
  from the engine, 10,000 matches by default; a page past it is an error the client reads). `@all` reads what
  the client asks for (`first`, an argument's `@limit`, else every match), 10,000 records at most at once,
  with an error next to them when that answers fewer than asked. The records load through the
  filters the database can apply too (`@trashed`'s, `@eq` on a column), so a stale index never
  answers one that no longer matches.

A model's `search_results` scope, when it has one, is what a search of it may return:
Searchkick loads the records it finds through it, so a record the index still holds after it
should have left is not returned. A search counts only what it can load: a Searchkick model
with a default scope (any, as declared) or `search_results` defines `search_where`, the
engine's `where:` for the same records, leaving out the soft-delete column Lighthouse filters on
itself, or the schema does not build; pages follow the
engine's positions, so a hit that does not load is never shown twice nor skips another. `@canQuery` on the field checks every record the search
finds, as PHP Lighthouse does (with Searchkick, 10,000 at most: more is an error), and the hits it
checked serve the field's page, in that resolution only.

Two `@search` arguments sent together, and (Searchkick) an argument whose directive an
engine cannot apply (`@neq`, `@orderBy`, `@whereConditions`, ...), are errors.
Schema errors, at build, where PHP Lighthouse fails when a query runs: a `within:` that is
not a string, a model that is not searchable, a `@search` nothing applies (graphql-ruby's
default reader, `@create`, ...), which PHP Lighthouse ignores, and, with Searchkick, a field with `scopes:`,
`@builder`, `@whereAuth` or `@orderBy(column:)`, or an `@canQuery` with `scopes:`, which PHP
Lighthouse **drops silently** when it searches (a search that skipped `@whereAuth` would
return records the user must not see), and a value graphql-ruby fills in without the client
(an argument's default, the fields of a default object) whose directive the engine cannot
apply, which would fail every search.

### `@orderBy`

```graphql
directive @orderBy(
  columns: [String!]               # argument: the columns the client may order by
  columnsEnum: String              # argument: an enum of them instead (one of the two)
  relations: [OrderByRelation!]    # argument: { relation:, columns:, columnsEnum: } to order by an aggregate
  column: String                   # field: the column to order by
  direction: OrderByDirection = ASC
) on ARGUMENT_DEFINITION | FIELD_DEFINITION
```

On an argument written as `_`, Lighthouse generates the clause input
(`<Type><Field><Arg>OrderByClause`, or `…RelationOrderByClause` with
`relations:`) and the column enum. Without `columns:`, `columnsEnum:` or
`relations:`, the argument takes the shared `OrderByClause`, which allows any
column. A column can be a JSON path, `meta->rank`, in `@orderBy` and in
`@whereConditions` ([JSON columns](filtering-and-ordering.md#json-columns)). On a field, `@orderBy(column:, direction:)` orders the result after
the client's clauses.

```graphql
type Query {
  posts(orderBy: _ @orderBy(columns: ["posted_at", "title"])): [Post!]! @all
  users(orderBy: _ @orderBy(relations: [{ relation: "posts" }])): [User!]! @all
  latestPosts: [Post!]! @all @orderBy(column: "posted_at", direction: DESC)
}

# { posts(orderBy: [{ column: POSTED_AT, order: DESC }]) { title } }
# { users(orderBy: [{ posts: { aggregate: COUNT }, order: DESC }]) { name } }
```

Guide: [filtering-and-ordering.md](filtering-and-ordering.md#ordering).

### `@whereConditions` / `@whereHasConditions`

```graphql
directive @whereConditions(columns: [String!], columnsEnum: String, handler: String) on ARGUMENT_DEFINITION
directive @whereHasConditions(relation: String, columns: [String!], columnsEnum: String, handler: String) on ARGUMENT_DEFINITION
```

These give clients a dynamic `WHERE` builder, with conditions joined by `AND`
and `OR`, PHP Lighthouse's `SQLOperator` operators, and `HAS` checks on
relations. On an argument written as `_`, Lighthouse generates the input
(`<Type><Field><Arg>WhereConditions` / `…WhereHasConditions`), its `…Relation`
and `…HasCondition` inputs, and the column enum. Without `columns:` or
`columnsEnum:`, the argument takes the shared `WhereConditions`, which allows
any column.

`@whereHasConditions` keeps the records with a related record matching the
conditions. The relation is `relation:`, or the argument's name without `has`.
`handler:` names a `Builders::` class whose `call(relation, conditions)` applies
the conditions instead.

```graphql
type Query {
  people(where: _ @whereConditions(columns: ["age", "type"])): [Person!]! @all
  users(hasPosts: _ @whereHasConditions(columns: ["title"])): [User!]! @all
}

# { people(where: { AND: [{ column: AGE, operator: GT, value: 37 }, { column: TYPE, value: "Actor" }] }) { name } }
# { users(hasPosts: { column: TITLE, operator: LIKE, value: "%Rails%" }) { name } }
```

Guide: [filtering-and-ordering.md](filtering-and-ordering.md#complex-where-conditions).

### `@trim`, `@hash`, `@drop`, `@bind` and `@upload`

Rewrite an argument's or input field's value before the field resolves, in the
order the SDL lists them:

| Directive | The resolver gets |
| --- | --- |
| `@trim` | the string without leading and trailing whitespace. On a field: every string it takes, nested inputs included |
| `@drop` | nothing: the argument is removed |
| `@hash` | the value hashed with BCrypt (the `bcrypt` gem, as `has_secure_password`) |
| `@bind(class:, column: "id", with: [], optional: false)` | the model record(s) the value identifies, eager-loading `with`; or what a class's `call(value, context)` returns |
| `@upload(disk:, path: "/", public: false)` | the signed id of the ActiveStorage blob the file was stored as, on the app's service `disk` names ([uploads.md](uploads.md)) |

```graphql
type Mutation {
  signUp(email: String! @trim, password: String! @hash, captcha: String @drop): User! @create
  assign(task: ID! @bind(class: "Task"), user: ID! @bind(class: "User", with: ["roles"])): Task!
  updateAvatar(avatar: Upload! @upload(path: "avatars")): User! @update @inject(context: "current_user.id", name: "id")
}
```

`@bind` fails the field with a validation error on the argument (`The selected task
is invalid.`) when no record matches, unless `optional: true`, which passes `null`.

`@globalId`, `@trim` and `@drop` only rewrite values: they run first, so `@guard`,
the `@can*` family and `@validator` see the result. `@hash`, `@bind` and `@upload`
run once those have let the call through: a validator sees the password before it
is hashed, and nothing is stored or looked up for a refused call.

### `@convertEmptyStringsToNull`

Replaces incoming empty strings `""` with `null`, before any resolver sees them —
directive resolvers (`@create`, `@all` filters, …), `@field`, `Resolvers::` /
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

Anyone may pass `trashed` unless you say who: `@softDeletes(ability: "view_trashed")`
puts [`@canModel`](authorization.md#who-may-use-an-argument) on the argument it adds,
so a client that passes `trashed` (any value) needs the ability on the model's policy.
Leaving `trashed` out lists the records as usual. PHP Lighthouse has no `ability:`.

```graphql
tasks: [Task!]! @all @softDeletes(ability: "view_trashed")
# tasks(trashed: Trashed @trashed @canModel(ability: "view_trashed")): [Task!]! @all
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
convention, like queries and mutations: a plain graphql-ruby
`GraphQL::Schema::Subscription` (`authorized?`, `subscribe`, `update`, ...).
`@subscription` names another one, and `@broadcast` triggers a subscription from
a mutation. The backend (ActionCable, ...) is the schema's; see
[subscriptions.md](subscriptions.md).

### `@subscription`

```graphql
directive @subscription(class: String!) on FIELD_DEFINITION
```

Names the class a `Subscription` field resolves to, when it does not follow the
convention (`postUpdated` → `Subscriptions::PostUpdated`). The class inherits from
`Subscriptions::BaseSubscription`, a `GraphQL::Schema::Subscription` that includes
`Lighthouse::GraphQL::Subscription` (PHP Lighthouse's `filter?` hooks), and is looked
up in `Config.namespaces[:subscriptions]`; a name with `::` is used as it is.

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
each passing through the class's `update` (or `filter?`). The class's
`self.trigger_arguments(root, context)` says which subscribers' arguments the
trigger must equal: none are needed for a field without arguments, and a plain
class with a required argument and no `trigger_arguments` is reported as a
`Lighthouse::DefinitionError`. A failed mutation, or a `nil` result, broadcasts
nothing. An unknown subscription name is a
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
| `when: FeatureState = ACTIVE` | The state the feature must be in for the element to be included: `ACTIVE` or `INACTIVE`. |

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

## Query complexity

### `@complexity`

Customize what a field costs in the query's complexity score, which graphql-ruby
checks against the schema's `max_complexity` before it runs the query.

```graphql
type Query {
  search(first: Int, term: String!): [Post!]! @complexity
  posts(includeFullText: Boolean): [Post!]! @all @complexity(resolver: "PostsComplexity")
}
```

| Argument | Meaning |
| --- | --- |
| `resolver: String` | A `GraphQL::Analysis::Analyzer` subclass in `namespaces[:analyzers]` (`Analyzers::PostsComplexity`), installed on the schema. With `Lighthouse::GraphQL::ComplexityAnalyzer` included, its `complexity` (a number, or a proc of `context, args, child_complexity`) is the field's cost. Without it, or without `resolver:`: `1 + child complexity × first`. |

Paginated fields cost `1 + child complexity × first` without the directive, and a
field resolved by a `GraphQL::Schema::Resolver` class costs what that class
declares. See [security.md](security.md).

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
