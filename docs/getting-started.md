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

does steps 1–5 below for you. It runs graphql-ruby's `graphql:install` first, for
the base classes every graphql-ruby app has (`Types::Base*`, `Resolvers::BaseResolver`,
`Mutations::BaseMutation`), then puts Lighthouse's own on top:

| File | What it is |
| --- | --- |
| `config/initializers/lighthouse.rb` | Every [configuration](configuration.md) option, commented out at its default |
| `graphql/schema.graphql` | A starter schema (`user` via `@find`, `users` via `@paginate`) that assumes a `User` model — skipped when the folder already holds `.graphql` files |
| `app/graphql/app_schema.rb` | The executable schema, built from the SDL, with `GraphQL::Dataloader` enabled and the base classes in `base_types` |
| `app/graphql/{types,resolvers,mutations,subscriptions}/base_*.rb` | graphql-ruby's base classes, and Lighthouse's `Subscriptions::BaseSubscription` |
| `app/controllers/graphql_controller.rb` | The endpoint, plus a `post '/graphql'` route |
| `graphql.config.yml` | IDE configuration — see [IDE support](#ide-support) |

`--schema=ApiSchema`, `--sdl-folder=app/schema`, `--skip-controller` and
`--skip-ide` change what it writes. Rerunning it is safe, and a schema class or
controller the app had before is kept (pass `--force` to replace it).
[generators.md](generators.md) has the details, every generator Lighthouse has, and
which of graphql-ruby's `graphql:*` generators fit a Lighthouse app.

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

## 2. Provide your base classes

Lighthouse builds on graphql-ruby, and follows its convention: each kind of class
inherits from a base class in its own namespace, where what they all share goes
once. graphql-ruby's `graphql:install` writes them, and `lighthouse:install` runs it;
by hand, run it yourself, then add the subscription base, which graphql-ruby has
none of, and make the mutation base a `GraphQL::Schema::Mutation` (the SDL declares a
mutation's arguments, where graphql-ruby's `RelayClassicMutation` takes one `input:`):

```shell
bin/rails generate graphql:install --no-relay --skip-graphiql
```

```ruby
# app/graphql/mutations/base_mutation.rb       — Mutation fields (Mutations::PublishPost)
module Mutations
  class BaseMutation < GraphQL::Schema::Mutation   # graphql-ruby writes RelayClassicMutation
    argument_class Types::BaseArgument
    field_class Types::BaseField
    object_class Types::BaseObject
  end
end

# app/graphql/subscriptions/base_subscription.rb — Subscription fields
module Subscriptions
  class BaseSubscription < GraphQL::Schema::Subscription
    include Lighthouse::GraphQL::Subscription
  end
end
```

Delete the `Types::QueryType` and `Types::MutationType` it writes: the SDL declares
the root types. The `Types::Base*` classes are the SDL's types' bases: the place to
mix in Apollo Federation or custom field and argument behavior.

```ruby
# app/graphql/types/base_object.rb
module Types
  class BaseObject < GraphQL::Schema::Object
    field_class Types::BaseField
    # include ApolloFederation::Object   # if you use federation
  end
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
      resolver: Resolvers::BaseResolver,
      mutation: Mutations::BaseMutation,
      subscription: Subscriptions::BaseSubscription,
      object: Types::BaseObject,
      # interface:, union:, enum:, input_object:, scalar: ...
    }
  }
)
```

`object:` and the other SDL kinds go to graphql-ruby, which builds the SDL's types
from them. `resolver:`, `mutation:` and `subscription:` are Lighthouse's: every
class a `Query`, `Mutation` or `Subscription` field resolves to must inherit from
its kind's base, and a `Subscription` field with no class of its own resolves with
the subscription base. See [resolvers.md](resolvers.md#base-classes).

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

`rails g lighthouse:install` writes the controller. It includes
`Lighthouse::GraphQL::Controller`, a concern that serves the schema:

```ruby
class GraphqlController < ApplicationController
  include Lighthouse::GraphQL::Controller

  lighthouse_schema AppSchema   # or 'AppSchema', or a block: lighthouse_schema { AppSchema }

  private

  # What @guard and the @can* directives read. Defaults to
  # { current_user: current_user } when the controller has a current_user.
  def graphql_context = { current_user: current_user }
end
```

Route to it (`post '/graphql', to: 'graphql#execute'`, plus a `get` for
[persisted queries](performance.md#persisted-queries) if you use them). Its
`execute` action:

- dispatches the [`StartRequest` and `EndRequest` events](events.md);
- reads `variables` (a JSON string, as a GET carries it, or parameters);
- runs the operation through `PersistedQueries.execute`, so
  [Automatic Persisted Queries](performance.md#persisted-queries) work once
  `config.persisted_queries` is on, and a JSON array body runs as a batch;
- sets the `Cache-Control` header the selected fields'
  [`@cacheControl`](caching.md) hints allow;
- renders the JSON; in development an error renders as JSON with its backtrace.

The hooks `graphql_context`, `graphql_schema` and `graphql_variables(param)` are
private methods you can override. A controller with an action of its own wraps it
in `lighthouse_request { ... }` to keep the request events:

```ruby
def search
  lighthouse_request do
    render json: Lighthouse::GraphQL::PersistedQueries.execute(AppSchema, query: params[:q], context: graphql_context)
  end
end
```

Not on the concern? Plain graphql-ruby works too:
`render json: AppSchema.execute(params[:query], variables: params[:variables], context: { current_user: current_user })`.

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
  schema: `<Type>Paginator`, `<Type>SimplePaginator`, `<Type>Connection`/`Edge`,
  `PaginatorInfo`, `SimplePaginatorInfo`, `PageInfo`, the `whereConditions`
  inputs and enums, and the `_` placeholder scalar.

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

## Custom resolvers and mutations

When a field needs Ruby, write a graphql-ruby resolver or mutation class named
after it — `Query.latestPosts` resolves to `Resolvers::LatestPosts`
(`app/graphql/resolvers/latest_posts.rb`, a `Resolvers::BaseResolver`),
`Mutation.publishPost` to `Mutations::PublishPost` (a `Mutations::BaseMutation`).
`bin/rails generate lighthouse:query LatestPosts` scaffolds one. See
[resolvers.md](resolvers.md).

## Next steps

- [Directives reference](directives.md) — the full vocabulary.
- [Resolvers, mutations & builders](resolvers.md), [Mutations](mutations.md),
  [Validation](validation.md), [Caching](caching.md).
- [Relationships](relationships.md) — wiring associations.
- [Filtering & ordering](filtering-and-ordering.md) — query constraints.
- [Apollo Federation](federation.md) — become a subgraph.
