# Getting Started

This guide takes you from an empty Rails app to a working, directive-driven
GraphQL endpoint.

## Install

```ruby
# Gemfile
gem 'lighthouse-graphql'
```

```shell
bundle install
```

Runtime dependencies (`graphql ~> 2.5`, `activesupport`) come with the gem. If you
want federation, add `apollo-federation` to your app — it is intentionally **not**
a hard dependency of Lighthouse so non-federated apps stay lean.

## The install generator

```shell
bin/rails generate lighthouse:install
```

does steps 1–5 below for you:

| File | What it is |
| --- | --- |
| `config/initializers/lighthouse.rb` | Every [configuration](configuration.md) option, commented out at its default |
| `graphql/schema.graphql` | A starter schema (`user` via `@find`, `users` via `@paginate`) that assumes a `User` model — skipped when the folder already holds `.graphql` files |
| `app/graphql/app_schema.rb` | The executable schema, with `GraphQL::Dataloader` enabled |
| `app/controllers/graphql_controller.rb` | The endpoint, plus a `post '/graphql'` route |
| `graphql.config.yml` | IDE configuration — see [IDE support](#ide-support) |

| Option | Effect |
| --- | --- |
| `--schema=ApiSchema` | Name of the schema constant (default `AppSchema`) |
| `--sdl-folder=app/schema` | Where the `.graphql` files live (default `graphql`); sets `config.sdl_folder` |
| `--skip-controller` | No controller or route — for apps that already serve GraphQL |
| `--skip-ide` | No `graphql.config.yml` or `.gitignore` entries |

Rerunning it is safe: the route and `.gitignore` entries are only added once, and
an existing schema class or controller is kept (pass `--force` to replace it).

It coexists with graphql-ruby's own tooling. The generators live under
`lighthouse:` and the rake task is `lighthouse:ide_helper`, next to graphql-ruby's
`graphql:*` generators and `graphql:schema:*` tasks. `graphql:install` writes the
same controller and route; whichever runs second finds the route already in place,
and Lighthouse keeps a controller graphql-ruby generated. In that case, have the
controller call `AppSchema.execute(...)` to serve the Lighthouse schema.

## 1. Write your schema (SDL)

By default Lighthouse loads every `*.graphql` file under `RAILS_ROOT/graphql`,
sorted by path and concatenated. Split your schema however you like:

```graphql
# graphql/schema.graphql
type Query {
  users: [User!]! @all
  user(id: ID! @eq): User @find
}

type User {
  id: ID!
  name: String
  email: String
}
```

`@all` resolves to `User.all`; `@find` resolves a single `User` by the `id`
argument (the `@eq` makes `id` a filter). Lighthouse infers the model from the
field's return type name (`User`), or you can be explicit with
`@all(model: "User")`.

## 2. Provide your base types

Lighthouse builds on graphql-ruby, so you supply the base classes it should use
for objects, interfaces, etc. — exactly the place to mix in Apollo Federation or
any custom field/argument behavior.

```ruby
# app/graphql/base_object.rb
class BaseObject < GraphQL::Schema::Object
  # include ApolloFederation::Object   # if you use federation
end
```

## 3. Build the schema

```ruby
# app/graphql/app_schema.rb
require 'lighthouse-graphql'

AppSchema = Lighthouse::GraphQL::RbLightHouse.get_schema(
  sdl_folder: Rails.root.join('graphql').to_s,
  options: {
    base_types: {
      object: BaseObject,
      # interface:, union:, enum:, input_object:, scalar: ...
    }
  }
)
```

`get_schema` returns a `GraphQL::Schema` subclass you can use directly, or
subclass further (e.g. to add federation, tracing, a Dataloader):

```ruby
class AppSchema < AppSchema   # or build a Base*Schema and subclass it
  use GraphQL::Dataloader
end
```

> Lighthouse uses graphql-ruby's `Dataloader` to batch relationship loads. Add
> `use GraphQL::Dataloader` to your schema to get N+1-free relationships.

## 4. Serve it

A standard graphql-ruby controller:

```ruby
class GraphqlController < ApplicationController
  def execute
    result = AppSchema.execute(
      params[:query],
      variables: params[:variables],
      context: { current_user: current_user },
      operation_name: params[:operationName]
    )
    render json: result
  end
end
```

## 5. Configure (optional)

Create an initializer to wire app-specific settings. This is also the single
place to register custom directives and federation reference resolvers, which
keeps Lighthouse itself free of any app constants.

```ruby
# config/initializers/lighthouse.rb
require 'lighthouse-graphql'

Lighthouse.configure do |config|
  # Namespaces tried when resolving a class referenced by a directive argument,
  # e.g. @field(resolver: "Users::Profile") or @all(model: "User").
  config.resolver_namespaces = ['App::Graphql', 'Resolvers']

  # How swallowed directive errors are surfaced (raise in test, log otherwise).
  # config.on_error = ->(error, _ctx) { Sentry.capture_exception(error) }
end
```

See [configuration.md](configuration.md) for all options.

## IDE support

Your IDE validates and autocompletes `.graphql` files against the schema it can
see. Lighthouse's directive definitions and the types its manipulation phase
generates live in Ruby, so without help the IDE flags `@paginate` as unknown and
can't resolve `UserPaginator`. PHP Lighthouse solves this with an IDE helper
command; so does Lighthouse for Rails:

```shell
bin/rails lighthouse:ide_helper              # writes to Rails.root
OUTPUT=tmp/ide bin/rails lighthouse:ide_helper
```

It writes two files:

- **`schema-directives.graphql`** — a definition for every registered directive,
  built-in or [your own](custom-directives.md), except those your SDL already
  declares (so the IDE never sees a duplicate).
- **`programmatic-types.graphql`** — the types Lighthouse adds to the executable
  schema: `<Type>Paginator`, `<Type>Connection`/`Edge`, `PaginatorInfo`,
  `PageInfo`, the `whereConditions` inputs and enums, and the `_` placeholder
  scalar.

Point your IDE's [graphql-config](https://the-guild.dev/graphql/config) at them
next to your SDL — the install generator writes this `graphql.config.yml`:

```yaml
schema:
  - graphql/**/*.graphql
  - schema-directives.graphql
  - programmatic-types.graphql
```

It works with the GraphQL plugin for JetBrains IDEs and the GraphQL extension for
VS Code. The files are derived from your schema, so the generator adds them to
`.gitignore`; rerun the task after changing the schema or registering a directive.

> The IDE reads fields as you wrote them: `users: [User!]! @paginate` still looks
> like a list to it, although clients query `users { data { … } }`. Field
> rewrites are not something an extra file can express.

## Casing: camelCase ↔ snake_case

GraphQL conventionally uses `camelCase` field names; Rails uses `snake_case`
attributes. Lighthouse bridges them with one rule: a field with no directive is
read off the parent object by its **snake_cased** name.

```graphql
type User {
  customAttributes: String   # reads user.custom_attributes
}
```

When the mapping isn't a simple `underscore`, use [`@rename`](directives.md#rename):

```graphql
type User {
  displayName: String @rename(attribute: "full_name")
}
```

## Next steps

- [Directives reference](directives.md) — the full vocabulary.
- [Relationships](relationships.md) — wiring associations.
- [Filtering & ordering](filtering-and-ordering.md) — query constraints.
- [Apollo Federation](federation.md) — become a subgraph.
