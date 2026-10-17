# Lighthouse for Ruby (`lighthouse-graphql`)

[![Gem Version](https://img.shields.io/gem/v/lighthouse-graphql.svg)](https://rubygems.org/gems/lighthouse-graphql)
[![CI](https://github.com/Vaz-Innovation/lighthouse-graphql/actions/workflows/ci.yml/badge.svg)](https://github.com/Vaz-Innovation/lighthouse-graphql/actions/workflows/ci.yml)
[![License](https://img.shields.io/github/license/Vaz-Innovation/lighthouse-graphql.svg)](./LICENSE.txt)

**SDL-first, directive-driven GraphQL for Ruby on Rails.**

Lighthouse lets you build a GraphQL API for your Rails app primarily through your
**schema** (SDL) and a set of server-side **directives** — `@all`, `@find`,
`@paginate`, `@hasMany`, `@belongsTo`, `@whereConditions`, `@orderBy`, `@field`,
`@auth` and more — instead of hand-writing a resolver for every field. It is a
Ruby adaptation of the PHP [Lighthouse](https://lighthouse-php.com) library,
built on top of [graphql-ruby](https://graphql-ruby.org), with first-class
**Apollo Federation** support so a Rails service can act as a subgraph.

```graphql
type Query {
  users: [User!]! @all
  user(id: ID! @eq): User @find
}

type User {
  id: ID!
  customAttributes: String        # resolves to user.custom_attributes automatically
  posts: [Post!]! @hasMany        # batched via a Dataloader
}
```

That's the whole resolver layer for those fields. No Ruby classes required.

---

## Why Lighthouse?

Writing a resolver class for every field is repetitive. The vast majority of
GraphQL fields do one of a handful of things: list a model, find one by id,
paginate, walk a relationship, or read an attribute. Lighthouse — like its PHP
inspiration — captures those patterns as **directives** you attach in the schema,
and falls back to a sensible default reader for plain fields. You write Ruby only
for the genuinely custom parts (`@field(resolver: "...")`), and your schema stays
the single source of truth.

### Inspirations

- **[Lighthouse (PHP)](https://lighthouse-php.com)** — the directive vocabulary,
  the SDL-first philosophy, and the arg-resolver / nested-mutation ideas.
- **[graphql-ruby](https://graphql-ruby.org)** — the execution engine,
  `Dataloader`, and the connection/pagination types Lighthouse builds on.
- **[Apollo Federation](https://www.apollographql.com/docs/federation/)** — so a
  Rails app can be one subgraph in a larger supergraph.

---

## Installation

Add the gem to your `Gemfile`:

```ruby
gem 'lighthouse-graphql'
```

It depends on `graphql ~> 2.5` and `activesupport`. For federation you also need
`apollo-federation` in your app (it is an optional, app-provided dependency).

Then let the generator set the app up:

```shell
bin/rails generate lighthouse:install
```

It creates the initializer, a starter schema in `graphql/schema.graphql`, the
`AppSchema` class, a `GraphqlController` with its `POST /graphql` route, and a
`graphql.config.yml` for your IDE. Run `bin/rails generate lighthouse:install --help`
for its options (`--schema`, `--sdl-folder`, `--skip-controller`, `--skip-ide`).

### IDE support

Lighthouse's directives and the types it generates (Paginator/Connection types,
`whereConditions` inputs, …) are defined in Ruby, so your IDE can't see them in
your `.graphql` files. Write them out for it:

```shell
bin/rails lighthouse:ide_helper
```

This writes `schema-directives.graphql` and `programmatic-types.graphql` to the app
root; the generated `graphql.config.yml` already points the GraphQL plugins for
JetBrains IDEs and VS Code at them. Rerun it after changing your schema or
registering a directive. See [docs/getting-started.md](docs/getting-started.md#ide-support).

## Quick start

Prefer to wire it by hand? These are the steps the generator performs.

1. **Put your SDL** in `app/graphql` or any folder (default: `RAILS_ROOT/graphql`),
   split across as many `.graphql` files as you like:

   ```graphql
   # graphql/users.graphql
   type Query {
     users: [User!]! @paginate
     user(id: ID! @eq): User @find
   }

   type User {
     id: ID!
     name: String
     email: String
     posts: [Post!]! @hasMany
   }
   ```

2. **Build the schema** (typically in `app/graphql/your_schema.rb`):

   ```ruby
   require 'lighthouse-graphql'

   AppSchema = Lighthouse::GraphQL::RbLightHouse.get_schema(
     sdl_folder: Rails.root.join('graphql').to_s,
     options: { base_types: { object: BaseObject } } # your graphql-ruby base classes
   )
   ```

3. **Execute** it from your controller exactly like any graphql-ruby schema:

   ```ruby
   AppSchema.execute(params[:query], variables: params[:variables], context: { current_user: current_user })
   ```

See **[docs/getting-started.md](docs/getting-started.md)** for the full setup,
including base types and configuration.

---

## Documentation

| Guide | What it covers |
| --- | --- |
| [Getting started](docs/getting-started.md) | Install, base types, building & serving the schema |
| [Directives reference](docs/directives.md) | Every built-in directive, grouped by purpose |
| [Relationships](docs/relationships.md) | `@hasMany`, `@belongsTo`, `@belongsToMany`, `@hasOne`, the `@morph*` variants, batching and `type:` pagination |
| [Filtering & ordering](docs/filtering-and-ordering.md) | `@eq`/`@where`/`@in`/`@like`, `@whereConditions`, `@orderBy` |
| [Queries, mutations & builders](docs/resolvers.md) | `Queries::` / `Mutations::` classes (graphql-ruby's contract), builders, generators |
| [Mutations](docs/mutations.md) | `@create`, `@update`, `@upsert`, `@delete` (and `*Many`), nested mutations on every kind of association, `@spread`, `@inject` |
| [Validation](docs/validation.md) | Model validations, `@validator` with Dry::Validation contracts |
| [Authentication & authorization](docs/authorization.md) | `@guard`, `@canFind` / `@canModel` / `@canQuery` / `@canResolved` / `@canRoot` (Pundit by default) |
| [Performance at scale](docs/performance.md) | Opt-in schema cache, SDL reloading in development, persisted queries (APQ) and trusted-document allowlists |
| [Caching](docs/caching.md) | `@cache`, `@cacheKey`, `@clearCache` (Rails.cache), `@cacheControl` (HTTP) |
| [Apollo Federation](docs/federation.md) | `@key`, `resolve_reference`, the `ReferenceResolver` registry |
| [Custom directives](docs/custom-directives.md) | The contracts, the registry, writing your own directive |
| [Configuration](docs/configuration.md) | `Lighthouse.configure`, namespaces, error handling |
| [Best practices](docs/best-practices.md) | Conventions worth adopting |

---

## How it works (one paragraph)

Lighthouse parses your SDL, runs a **manipulation phase** (directives that need to
reshape the schema — e.g. `@paginate` injecting a Paginator type, `@whereConditions`
generating input types), builds an executable schema with
`GraphQL::Schema.from_definition`, then runs a **resolution phase** that attaches
behavior to fields (directives that resolve data, wrap resolvers, or compose query
constraints). Every directive is a small class registered with a
`Lighthouse::DirectiveRegistry`; adding one is "write a class and register it." A
single `Support::Naming` rule maps GraphQL `camelCase` to Rails `snake_case`, so
attribute reads "just work" with `@rename` as the explicit override.

## License

MIT. See [LICENSE.txt](LICENSE.txt).
