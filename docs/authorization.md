# Authentication & Authorization

Enforce **authentication** and **authorization** declaratively in your schema,
instead of in resolvers whose only job is a policy check. `@guard` requires a
user. The `@can*` family checks a policy ability, Pundit by default. This is PHP
Lighthouse's v6 design, which replaced its single `@can` with one directive per
*thing being authorized*.

## Configuration

The defaults work with a Rails app that puts `current_user` (or `pundit_user`)
in the GraphQL context and uses Pundit, so **typically no configuration is
needed**:

```ruby
Lighthouse.configure do |config|
  # The authenticated user (nil if none). Default:
  config.authenticated_user = ->(ctx) { ctx[:current_user] }

  # The "user" handed to policies. Default: ctx[:pundit_user], else the authenticated user.
  config.policy_user = ->(ctx) { ctx[:pundit_user] }

  # How an ability is checked. Default (Pundit):
  config.authorizer = ->(user, record, ability, args = []) do
    Pundit.policy!(user, record).public_send("#{ability}?", *args)
  end
end
```

Point `authorizer` at any system (CanCanCan, ActionPolicy, a lambda) to use
something else. It receives `args` only when a directive passes some, so a
three-argument authorizer keeps working for checks without them.

## `@guard` — require authentication

Raises `Unauthenticated.` when there is no user, with `extensions.code`
`UNAUTHENTICATED`, Apollo's code, so a client can send the user to sign in without
matching the message. It runs before everything else on the field.

```graphql
type Query {
  me: User @guard
}
```

## The `@can*` family

Each directive checks `ability` with the policy, e.g. `PostPolicy#update?` for
`ability: "update"`. They differ in what they authorize:

| Directive | Authorizes | Typical use |
| --- | --- | --- |
| `@canModel` | the model **class** | `create?` before `@create` |
| `@canFind` | the models whose keys an argument holds | `update?` before `@update` |
| `@canQuery` | the models the field's argument filters select | bulk reads or writes |
| `@canResolved` | what the field resolved to (each item of a list) | read-only fields |
| `@canRoot` | the parent object | a sensitive field on a type |

```graphql
type Query {
  post(id: ID! @eq): Post @find @canResolved(ability: "show")
  draftCount(authorId: ID @eq): Int @count(model: "Post") @canQuery(ability: "show")
}

type Mutation {
  createPost(input: CreatePostInput! @spread): Post @create @canModel(ability: "create")
  updatePost(input: UpdatePostInput! @spread): Post @update @canFind(ability: "update", find: "input.id")
}

type User {
  email: String @canRoot(ability: "view_email")
}
```

With Pundit, `@canFind(ability: "update", find: "input.id")` loads the post and
calls `PostPolicy.new(pundit_user, post).update?`. `@canModel(ability: "create")`
calls `PostPolicy.new(pundit_user, Post).create?`.

All of them run **before** the field resolves, except `@canResolved`. That one
needs the result, so use it only on fields that do not change data.

### Arguments

Every `@can*` directive takes:

| Argument | Meaning |
| --- | --- |
| `ability: String!` | The policy method, without `?` |
| `injectArgs: Boolean = false` | Pass the field's arguments (a Hash) to the policy method |
| `args: CanArgs` | Static values passed after them, e.g. `args: 2` or `args: ["a", "b"]` |
| `action: CanAction = EXCEPTION_PASS` | What a denial does (below) |
| `returnValue: CanArgs` | The value returned for `action: RETURN_VALUE` |

```ruby
class PostPolicy < ApplicationPolicy
  def publish?(args)      # @canFind(ability: "publish", find: "id", injectArgs: true)
    user.admin? && args[:title] != record.title
  end

  def edit?(level)        # @canFind(ability: "edit", find: "id", args: 2)
    user.level >= level
  end
end
```

Plus, per directive:

- `@canFind(find: String!, model: String, findOrFail: Boolean = true, scopes: [String!])`.
  `find` is the argument holding the primary key or keys, and may be a dot path
  (`"input.id"`). A key that matches no record fails with
  `Couldn't find Post with 'id'=…`, unless `findOrFail: false`. Nothing at the path (a
  misspelt one, or an optional argument the client left out) fails with
  `Got no key to find a model at the expected input path: …`, as in PHP Lighthouse;
  a `*` over an empty list (`"inputs.*.id"`) checks no model. `scopes` are model
  scopes applied to the lookup.
- `@canModel(model: String)`.
- `@canQuery(model: String, scopes: [String!])`. `scopes` narrow the records
  being authorized, not the field's result. On a field the client searches
  ([`@search`](filtering-and-ordering.md#canquery-on-a-searched-field)), the records are
  the ones the search finds, every one and not only the page, as in PHP Lighthouse;
  with Searchkick, 10,000 at most (a search that finds more a page could reach is an
  error), and `scopes` are a schema error, as the engine cannot apply them.

The model defaults to the `model:` of another directive on the field (as in
`@count(model: "Post") @canQuery`), then to the field's return type.

### `action`: what a denial does

| `action` | Result |
| --- | --- |
| `EXCEPTION_PASS` (default) | The error reaches the client: `This action is unauthorized.`, or `@canFind`'s not-found message |
| `EXCEPTION_NOT_AUTHORIZED` | Always `This action is unauthorized.`, which hides whether a record exists |
| `RETURN_VALUE` | The field returns `returnValue` instead of resolving |

```graphql
post(id: ID!): Post @canFind(ability: "show", find: "id", action: EXCEPTION_NOT_AUTHORIZED)
```

`action` applies to the directive's own checks only. Errors from the resolver
itself are untouched.

`This action is unauthorized.` carries `extensions.code` `FORBIDDEN`, as Apollo
names it (`@guard`'s `Unauthenticated.` carries `UNAUTHENTICATED`):

```json
{ "message": "This action is unauthorized.", "path": ["post"], "extensions": { "code": "FORBIDDEN" } }
```

PHP Lighthouse's errors have no code. Raise `Lighthouse::AuthenticationError` and
`Lighthouse::AuthorizationError` from your own resolvers to answer the same.

### Who may use an argument

Some arguments are for some users only: `trashed` for admins, a filter on drafts
for editors. `@canModel` on an argument, or on an input field at any depth, checks
its ability against the model only when the client gives that argument a value, and
denies the whole field otherwise, as `@canModel` on the field does (`action:` too):

```graphql
type Query {
  posts(filter: PostFilter): [Post!]! @all
  tasks(trashed: Trashed @trashed @canModel(ability: "view_trashed")): [Task!]! @all
}

input PostFilter {
  title: String @like
  status: PostStatus @eq @canModel(ability: "filter_by_status", model: "Post")
}
```

```ruby
class TaskPolicy < ApplicationPolicy
  def view_trashed? = user&.admin?
end
```

It runs with the field's `@can*` directives, before the field resolves. The model is
the directive's `model:`, else the field's, as for `@canModel` on a field.
`@softDeletes(ability:)` writes it on the `trashed` argument for you.

## Ordering

The order you write directives in does not matter. They run as:

1. `@guard` / `@auth` (authentication)
2. `@canFind`, `@canModel`, `@canQuery`, `@canRoot` (and the check of `@canResolved`, after the resolver)
3. `@validator` (see [validation.md](validation.md))
4. `@cache`, then the resolver

So a cached value is still authorized on every request.

## Multi-tenancy vs. authorization

Keep the two layers distinct:

- **Tenancy / scoping** decides which account's records are visible. It belongs in
  a [builder](resolvers.md#builders) or query class, e.g. `account.posts`.
- **Authorization** decides whether this user may do this to this record. It
  belongs in `@can*` and your policies.

For lists, scope with a builder (e.g. Pundit's `policy_scope`) rather than
authorizing item by item.

## Records reached through a relation

A field's directives guard that field only. A client reaches the same records
through every relation in the graph, so a rule on the root field doesn't follow
them:

```graphql
type Query {
  posts: [Post!]! @paginate(scopes: ["published"])   # drafts left out here…
}

type Comment {
  post: Post @belongsTo                               # …and reachable here
}
```

`{ me { comments { data { post { title } } } } }` answers each comment's post,
published or not. `@guard` doesn't change that: it checks that someone is signed
in, not what they may see. Put a row-level rule where every path goes through it:

| Where | How | Covers |
| --- | --- | --- |
| **The type** | `scope_items` / `authorized?` on `Types::PostType` | every record of the type, whatever field reaches it |
| The association | `belongs_to :post, -> { published }` | every field on that association, still batched |
| The field | `@belongsTo(scopes: ["published"])`, or a [`@builder`](resolvers.md#builders) | that field; one query per parent (paginated relations stay batched) |
| Each record | `@canResolved(ability: "show")` | that field, each item checked by the policy after it loads |

### On the type: `scope_items` and `authorized?`

The type is the place for a rule that must hold everywhere. Lighthouse runs
graphql-ruby's type-level hooks on the [type class](types.md) of an SDL type, the
`Types::<Name>Type` that includes `Lighthouse::GraphQL::Type`:

```ruby
# app/graphql/types/post_type.rb
class Types::PostType < Types::BaseObject
  include Lighthouse::GraphQL::Type

  # The Posts Lighthouse queries, narrowed in the query itself.
  def self.scope_items(posts, context)
    Pundit.policy_scope!(context[:current_user], posts)
  end

  # Each Post a field returns; false hides it.
  def self.authorized?(post, context)
    super && Pundit.policy!(context[:current_user], post).show?
  end
end
```

- **`scope_items`** gets a relation and must answer one. Lighthouse applies it in
  every query it builds for records of the type: `@all`, `@paginate` (so its total
  is right), `@find`, `@first`, the relationship directives, `resolve_info.enhance_builder`
  and Federation's `_entities`. A relationship that batches keeps batching: what it
  loads for every parent is checked in one more query. A count that answers no
  records of a type (`@count(model: "Post")`, `@aggregate`, `@withCount`) is scoped
  by the type whose model it counts; two types of one model that both define
  `scope_items` make such a count an error, never an unscoped answer.
- **`authorized?`** runs where graphql-ruby runs it, for each object of the type any
  field returns, at any depth. A refusal goes to your schema's `unauthorized_object`,
  which answers `null` by default.

Prefer `scope_items` for rows: `authorized?` hides an object after it loads, so a
refused item of a `[Post!]!` list nulls the whole list, and a page still counts it.
A field searched outside the database (`@search` with Searchkick) can't take
`scope_items`, as it can't take `scopes:`: such a search is an error, never an
unscoped answer. Records your own code loads (a type method, a resolver class that
doesn't call `enhance_builder`) are yours to scope.

What it costs, measured on PostgreSQL ([performance.md](performance.md#type-level-authorization)):

- A type whose class defines neither hook costs nothing: Lighthouse reads which
  ones do when the schema is built, and leaves the others as graphql-ruby has them.
- `authorized?` costs what your method does: nothing measurable on top of it.
- `scope_items` is free where Lighthouse builds the query (a root field, a page and
  its total, a count, `@find`, batched or not): it is part of that one query. A
  relationship it loads in a batch is checked in one more query per batch, about
  10 µs per record loaded: 4,000 posts across 200 users took 35 ms more (5%),
  20,000 took 8% more, in the same number of queries whatever the parents.

Rails' reloader rebuilds the schema with your code, so a hook you add or remove
in development applies on the next request.

### On the association or the field

The association needs no Lighthouse: the relationship directives load through
Active Record's preloader, so its scope applies at any depth, in one query per
batch. For a rule on one field that depends on the user, a builder applies
Pundit's scope:

```graphql
type Comment {
  post: Post @belongsTo @builder(class: "PolicyScope")
}
```

```ruby
# app/graphql/builders/policy_scope.rb
class Builders::PolicyScope
  def self.call(relation, _args, context)
    Pundit.policy_scope!(context[:current_user], relation)
  end
end
```

A singular field a rule can empty must be nullable (`post: Post`, not `Post!`),
or the hidden record fails its parent instead. `@canResolved` with
`action: RETURN_VALUE` answers `null` for a record the policy refuses, instead of
an error.

Exposing the API to an AI agent (e.g. [Apollo MCP Server](https://www.apollographql.com/docs/apollo-mcp-server))
doesn't change this: the agent runs only the operations you ship, but the endpoint
behind it answers any query.

## Migrating from `@can`

`@can` is gone. Its modes map one to one:

| Before | After |
| --- | --- |
| `@can(ability: "show")` | `@canResolved(ability: "show")` |
| `@can(ability: "view_email", root: true)` | `@canRoot(ability: "view_email")` |
| `@can(ability: "update", find: "id", model: "Post")` | `@canFind(ability: "update", find: "id", model: "Post")` |

One difference: `@canResolved` authorizes **each item** of a list. `@can` skipped
lists.
