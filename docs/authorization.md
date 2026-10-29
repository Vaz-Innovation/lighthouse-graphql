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

Raises `Unauthenticated.` when there is no user. It runs before everything else
on the field.

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
  being authorized, not the field's result.

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

## Migrating from `@can`

`@can` is gone. Its modes map one to one:

| Before | After |
| --- | --- |
| `@can(ability: "show")` | `@canResolved(ability: "show")` |
| `@can(ability: "view_email", root: true)` | `@canRoot(ability: "view_email")` |
| `@can(ability: "update", find: "id", model: "Post")` | `@canFind(ability: "update", find: "id", model: "Post")` |

One difference: `@canResolved` authorizes **each item** of a list. `@can` skipped
lists.
