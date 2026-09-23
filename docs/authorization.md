# Authentication & Authorization

Lighthouse lets you enforce **authentication** and **authorization** declaratively
in your schema with the `@guard` and `@can` directives — instead of hand-writing
a resolver whose only job is a policy check. This mirrors PHP Lighthouse's
`@guard` / `@can*` family, adapted to Ruby and your authorization library (Pundit
by default).

## Configuration

The library is framework-agnostic: how it reads the current user and how it
checks an ability are both configurable. The defaults work with a Rails app that
puts `current_user` / `pundit_user` in the GraphQL context and uses Pundit, so
**typically no configuration is needed**:

```ruby
Lighthouse.configure do |config|
  # The authenticated user (nil if none). Default:
  config.authenticated_user = ->(ctx) { ctx[:current_user] }

  # The "user" passed to the authorizer. Default: ctx[:pundit_user], falling back
  # to the authenticated user.
  config.policy_user = ->(ctx) { ctx[:pundit_user] }

  # How an ability is checked. Default uses Pundit:
  config.authorizer = ->(user, record, ability) { Pundit.policy!(user, record).public_send("#{ability}?") }
end
```

Point `authorizer` at any system (CanCanCan, ActionPolicy, a plain lambda) to use
something other than Pundit.

## `@guard` — require authentication

Require an authenticated user before a field resolves. Raises `Unauthenticated.`
otherwise.

```graphql
type Query {
  me: User @field(resolver: "Resolvers::CurrentUser") @guard
}
```

`@guard` runs **outermost** — before any other directive on the field.

## `@can` — authorize with a policy

Check a policy ability. By default it authorizes the **resolved record**: the
field resolves first, then `@can` checks the ability against the result (and
raises if denied). `nil` results pass through; collections are left to scoping.

```graphql
type Query {
  # Resolve the (account-scoped) contact, then authorize ContactPolicy#show?
  contact(id: ID!): Contact
    @field(resolver: "Resolvers::ContactResolver")
    @can(ability: "show")
}
```

```ruby
# The resolver is now just a scoped finder — no authorization boilerplate.
module Resolvers
  class ContactResolver
    def self.call(_obj, args, ctx)
      account = ctx[:current_account]
      account.contacts.find_by(id: args[:id]) || raise(GraphQL::ExecutionError, 'Contact not found.')
    end
  end
end
```

With Pundit, `@can(ability: "show")` calls `ContactPolicy.new(pundit_user, contact).show?`.

### Other modes

```graphql
# Authorize against the parent object (e.g. restrict a field on a type):
type User {
  email: String! @can(ability: "view_email", root: true)
}

# Find a model by an argument and authorize it before resolving:
type Mutation {
  archivePost(id: ID!): Post @can(ability: "update", find: "id", model: "Post") @field(resolver: "...")
}
```

`@can` is `repeatable`, so you can require multiple abilities.

## Multi-tenancy vs. authorization

Keep the two layers distinct:

- **Tenancy / scoping** (which account's records are visible) belongs in your
  resolver or an `@builder` — e.g. `account.contacts`. This is application-specific.
- **Authorization** (may this user perform this action on this record) belongs in
  `@can` + your policies.

For list fields, filter with a policy **scope** in a builder (e.g. Pundit's
`policy_scope`) rather than authorizing item-by-item.

## Ordering

When several wrapping directives are on one field, they run in this order:

1. `@guard` / `@auth` (authentication) — outermost
2. `@can` (authorization of the resolved value)
3. the field's data resolver (`@field`, `@all`, `@hasMany`, …) — innermost
