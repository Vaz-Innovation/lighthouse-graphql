# Getting Started

This guide takes you from an empty Rails app to a working, directive-driven
GraphQL endpoint.

## Install

Lighthouse is built on [graphql-ruby](https://graphql-ruby.org), and the two are
set up together, in three commands:

**The gems.** `lighthouse-graphql` depends on `graphql ~> 2.5`, so adding it
installs graphql-ruby too:

```ruby
# Gemfile
gem 'lighthouse-graphql'
```

```shell
bundle install
```

You can also list `gem 'graphql'` yourself, to pin its version. On graphql 2.5, keep
the `json` gem below 3: graphql 2.5 calls `JSON.generate` with an option json 3
removed (graphql 2.6 no longer does). If you want federation, add `apollo-federation`
to your app — it is intentionally **not** a hard dependency of Lighthouse so
non-federated apps stay lean.

**graphql-ruby's install** (optional). This writes the schema class, the base
classes (`Types::BaseObject`, ...), the root types and the controller. Choose its
options here, as for any graphql-ruby app (`--relay`, `--batch`, `--api`,
`--schema=ApiSchema`, `--skip-mutation-root-type`, ...):

```shell
bin/rails generate graphql:install
```

**Lighthouse's install.** It adapts what graphql-ruby wrote and adds its own files
(see below). If you skipped graphql-ruby's install, it runs `graphql:install` for you,
with graphql-ruby's defaults, so the two commands are never both required:

```shell
bin/rails generate lighthouse:install
```

Run `graphql:install` yourself only to pass it options; Lighthouse then keeps them.

## The install generator

`bin/rails generate lighthouse:install` does steps 1–5 below for you. It builds on
graphql-ruby's own install, `rails g graphql:install`, with whichever of its options
the app chose (`--relay`, `--batch`, `--api`, ...). When the app has no graphql-ruby schema class yet, it runs
`graphql:install` first, with graphql-ruby's defaults. Then it adapts what
graphql-ruby wrote, and adds Lighthouse's own:

| File | What it is |
| --- | --- |
| `app/graphql/app_schema.rb` | graphql-ruby's schema class, now built by Lighthouse from the SDL on every class graphql-ruby wrote (`base_types`). The rest of the class is graphql-ruby's |
| `app/graphql/types/query_type.rb`, `mutation_type.rb` | graphql-ruby's root types, which the SDL's `Query` and `Mutation` are built on. Their example `test_field` goes; Relay's `node` / `nodes` stay |
| `app/graphql/types/base_*.rb`, `resolvers/base_resolver.rb`, `mutations/base_mutation.rb` | graphql-ruby's base classes. `BaseObject`, `BaseInterface`, `BaseUnion` and `BaseScalar` include `Lighthouse::GraphQL::Type` |
| `app/controllers/graphql_controller.rb` | graphql-ruby's controller, replaced by one including `Lighthouse::GraphQL::Controller` |
| `config/initializers/lighthouse.rb` | Every [configuration](configuration.md) option, commented out at its default |
| `graphql/schema.graphql` | The schema's entrypoint: a starter schema (`user` via `@find`, `users` via `@paginate`) that assumes a `User` model. With graphql-ruby's Relay, also `node(id:)` and `nodes(ids:)` (see [relay.md](relay.md#relay-through-graphql-ruby)). Skipped when the file exists |
| `graphql.config.yml` | IDE configuration — see [IDE support](#ide-support) |

`--schema=ApiSchema`, `--schema-path=app/schema/schema.graphql`, `--subscriptions`,
`--skip-controller` and `--skip-ide` change what it does. Rerunning it changes
nothing, and a controller the app changed is kept.
[generators.md](generators.md) has the details, every generator Lighthouse has, and
which of graphql-ruby's `graphql:*` generators fit a Lighthouse app.

## 1. Write your schema (SDL)

Lighthouse reads the schema from one entrypoint, `RAILS_ROOT/graphql/schema.graphql`
(`config.schema_path`), as PHP Lighthouse does:

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

To split the schema, the entrypoint imports the other files. A type is defined
once, and the other files add to it with `extend type`:

```graphql
# graphql/schema.graphql
type Query

#import user.graphql
#import blog/*.graphql
```

```graphql
# graphql/user.graphql
type User {
  id: ID!
  name: String
}

extend type Query {
  users: [User!]! @all
}
```

A file nothing imports is not part of the schema, and a type defined twice is an
error. See [schema-organisation.md](schema-organisation.md).

## 2. Provide your base classes

Lighthouse builds on graphql-ruby, and follows its convention: each kind of class
inherits from a base class in its own namespace, where what they all share goes
once. graphql-ruby's `graphql:install` writes them, and `lighthouse:install` builds
on them. By hand, run graphql-ruby's install with its defaults:

```shell
bin/rails generate graphql:install
```

Then include `Lighthouse::GraphQL::Type` in the base object, interface, union and
scalar, so every type class that inherits from them lends its methods to the SDL
type of its name (see [type classes](resolvers.md#type-classes)):

```ruby
# app/graphql/types/base_object.rb
module Types
  class BaseObject < GraphQL::Schema::Object
    include Lighthouse::GraphQL::Type
    edge_type_class(Types::BaseEdge)
    connection_type_class(Types::BaseConnection)
    field_class Types::BaseField
    # include ApolloFederation::Object   # if you use federation
  end
end
```

Add the subscription base, which graphql-ruby has none of, if the schema has a
`Subscription` type (`lighthouse:install --subscriptions` writes it):

```ruby
# app/graphql/subscriptions/base_subscription.rb — Subscription fields
module Subscriptions
  class BaseSubscription < GraphQL::Schema::Subscription
    include Lighthouse::GraphQL::Subscription
  end
end
```

graphql-ruby's `Mutations::BaseMutation` stays a `RelayClassicMutation`. A
`Mutation` field that declares its arguments one by one calls it as a plain
mutation, with those arguments as keywords; one with a single `input:` argument
goes through `RelayClassicMutation`'s own `input:` handling.

## 3. Build the schema

graphql-ruby's schema class becomes Lighthouse's: it inherits from the schema
`get_schema` builds from the SDL, instead of `GraphQL::Schema`.

```ruby
# app/graphql/app_schema.rb
class AppSchema < Lighthouse::GraphQL::RbLightHouse.get_schema(
  options: {
    base_types: {
      query_type: Types::QueryType,
      mutation_type: Types::MutationType,
      node: Types::NodeType,
      resolver: Resolvers::BaseResolver,
      mutation: Mutations::BaseMutation,
      subscription: Subscriptions::BaseSubscription,
      object: Types::BaseObject,
      interface: Types::BaseInterface,
      union: Types::BaseUnion,
      scalar: Types::BaseScalar,
      enum: Types::BaseEnum,
      input_object: Types::BaseInputObject
    }
  }
)
  # Lighthouse batches relationship loads through graphql-ruby's Dataloader.
  use GraphQL::Dataloader

  max_depth(15)
  max_query_string_tokens(5000)
  validate_max_errors(100)

  # Relay-style Object Identification, as graphql-ruby's install writes it:
  def self.id_from_object(object, type_definition, query_ctx)
    object.to_gid_param
  end

  def self.object_from_id(global_id, query_ctx)
    GlobalID.find(global_id)
  end
end
```

The SDL is read from `config.schema_path` and the files it imports
(`get_schema(schema_path: ...)` overrides it). The class body is graphql-ruby's, so plugins and settings go there as in any
graphql-ruby schema (`use ...`, `max_complexity(...)`), but for `query(...)` and
`mutation(...)`, which the SDL's root types replace, and `resolve_type`, which
Lighthouse answers (see [types.md](types.md)).

`object:` and the other SDL kinds go to graphql-ruby, which builds the SDL's types
from them. `query_type:` and `mutation_type:` are the classes the SDL's `Query` and
`Mutation` are built on, so their own `field`s (Relay's `node` / `nodes`) are the
schema's too; `node:` is the SDL's `Node` interface (see [relay.md](relay.md)).
`resolver:`, `mutation:` and `subscription:` are Lighthouse's: every class a
`Query`, `Mutation` or `Subscription` field resolves to must inherit from its kind's
base, and a `Subscription` field with no class of its own resolves with the
subscription base. See [resolvers.md](resolvers.md#base-classes).

A constant works as well, with the settings passed as options or set on it:

```ruby
AppSchema = Lighthouse::GraphQL::RbLightHouse.get_schema(
  options: { base_types: { object: Types::BaseObject }, using: { GraphQL::Dataloader => {} } }
)
```

> Lighthouse uses graphql-ruby's `Dataloader` to batch relationship loads. Keep
> `use GraphQL::Dataloader` in your schema to get N+1-free relationships.

## 4. Serve it

`rails g lighthouse:install` replaces graphql-ruby's controller (when the app has
not changed it) with one including `Lighthouse::GraphQL::Controller`, a concern that
serves the schema:

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
private methods you can override.

### Running an operation from another action

To render a page with its data already loaded, run the operation from the action
with `lighthouse_execute`, from `Lighthouse::GraphQL::Operations` (which
`Lighthouse::GraphQL::Controller` includes). It runs the operation as the endpoint
does, with the endpoint's context: `graphql_context`, and the client's IP and the
controller `@throttle` counts with. It returns the result, or `nil` when a
`@throttle` answered the request with a 429:

```ruby
class PagesController < ApplicationController
  include Lighthouse::GraphQL::Operations

  lighthouse_schema AppSchema

  def search
    @results = lighthouse_execute('query Search($term: String!) { searchPosts(term: $term) { title } }',
                                  variables: { term: params[:term] })
    return if performed? # @throttle answered 429
  end

  private

  def graphql_context = { current_user: current_user }
end
```

`extensions:` runs a persisted query by its hash, and `context:` adds to the
context. The operation events (`StartOperationOrOperations`, `StartExecution`, ...)
fire as for a client's request. The request events (`StartRequest`, `EndRequest`)
are the GraphQL endpoint's, one per GraphQL request, as PHP Lighthouse's controller
dispatches them; wrap an action in `lighthouse_request { ... }` to dispatch them
around it.

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
command, and so does Lighthouse for Rails. In development, an app with a
`graphql.config.yml` gets the files rewritten on boot and on every reload
(`config.ide_helper`), so you never run it by hand there. Elsewhere:

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
  `PaginatorInfo`, `SimplePaginatorInfo`, `PageInfo`, the `@whereConditions` and
  `@orderBy` inputs and enums, and the `_` placeholder scalar (always declared,
  even before the SDL uses it; without it, the IDE reports `Unknown type "_"`).
  It is for the IDE only: the schema Lighthouse builds has no `_` type. It leaves
  out every type the SDL or `schema-directives.graphql` defines, because
  graphql-js, which the IDE plugins use, rejects a type defined twice.

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
`.gitignore`. Outside development, rerun the task after changing the schema or
registering a directive. The IDE reads every `.graphql` file the glob matches, as
one schema: it does not follow `#import`.

> The IDE reads fields as you wrote them: `users: [User!]! @paginate` still looks
> like a list to it, although clients query `users { data { … } }`. Field
> rewrites are not something an extra file can express.

### The schema clients see

Print it, as PHP Lighthouse's `lighthouse:print-schema` does: every type Lighthouse
generated, the fields rewritten (`users { data { … } }`), and none of Lighthouse's
directives, which instruct the server and are not part of the schema clients get
(nor of introspection). The task writes the SDL to stdout and nothing else:

```shell
bin/rails lighthouse:print_schema                        # <App>Schema, else AppSchema
SCHEMA=Admin::Schema bin/rails lighthouse:print_schema > generated.graphql
FORMAT=json bin/rails lighthouse:print_schema            # the introspection result
FORMAT=federation bin/rails lighthouse:print_schema      # a subgraph's SDL, with @key, ...
bin/rails lighthouse:print_schema WRITE=1                # config.schema_output, else lighthouse-schema.graphql
bin/rails lighthouse:print_schema WRITE=schema.graphql   # that file
```

graphql-ruby prints types, fields, arguments and enum values in alphabetical order,
so the output is stable (PHP Lighthouse's `--sort`). `WRITE` leaves an unchanged
file alone. For a codegen, let development keep the file up to date with
[`schema_output`](configuration.md#schema-output), and check it in CI with
`bin/rails lighthouse:schema_output:verify`.

The schema is the one of the environment it is printed in: a field with
`@show(env: ["development"])` is in development's and not in production's. Print
the file a production client relies on with `RAILS_ENV=production` when the schema
uses `@show` or `@hide`.

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
A method of the root type class comes first, as in graphql-ruby: `Query.latestPosts`
calls `Types::QueryType#latest_posts` when it defines one. `bin/rails generate
graphql:mutation PublishPost` writes a code-first mutation. See
[resolvers.md](resolvers.md).

## Next steps

- [Directives reference](directives.md) — the full vocabulary.
- [Resolvers, mutations & builders](resolvers.md), [Mutations](mutations.md),
  [Validation](validation.md), [Caching](caching.md).
- [Relationships](relationships.md) — wiring associations.
- [Filtering & ordering](filtering-and-ordering.md) — query constraints.
- [Apollo Federation](federation.md) — become a subgraph.
