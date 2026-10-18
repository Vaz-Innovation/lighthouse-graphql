# Generators

Lighthouse builds on graphql-ruby, and so do its generators: it writes only what
graphql-ruby has no generator for, or what an SDL-first schema needs differently.
Every graphql-ruby app's base classes (`Types::BaseObject`, `Resolvers::BaseResolver`,
`Mutations::BaseMutation`, ...) come from graphql-ruby's own `graphql:install`.

## `lighthouse:install`

```shell
bin/rails generate lighthouse:install
```

It runs graphql-ruby's install first
(`graphql:install --no-relay --skip-graphiql --skip-query-logs`), which writes:

- `app/graphql/types/base_*.rb`: `BaseObject`, `BaseField`, `BaseArgument`,
  `BaseInterface`, `BaseUnion`, `BaseScalar`, `BaseEnum`, `BaseInputObject`;
- `app/graphql/resolvers/base_resolver.rb` and `app/graphql/mutations/base_mutation.rb`;
- its schema class, `Types::QueryType`, `Types::MutationType` and controller, and the
  `POST /graphql` route.

Then Lighthouse puts its own on top of what graphql-ruby wrote in that run:

| File | What Lighthouse does |
| --- | --- |
| `app/graphql/app_schema.rb` | Replaced by the schema built from the SDL, naming every base class in `base_types` |
| `app/controllers/graphql_controller.rb` | Replaced by one including `Lighthouse::GraphQL::Controller` |
| `app/graphql/types/query_type.rb`, `mutation_type.rb` | Removed: the SDL declares the root types |
| `app/graphql/mutations/base_mutation.rb` | Made a `GraphQL::Schema::Mutation`: the SDL declares a mutation's arguments, where graphql-ruby's `RelayClassicMutation` takes a single `input:` |
| `app/graphql/subscriptions/base_subscription.rb` | Written: graphql-ruby has no subscription base. It includes `Lighthouse::GraphQL::Subscription` |
| `config/initializers/lighthouse.rb` | Written: every [configuration](configuration.md) option, commented out |
| `graphql/schema.graphql` | A starter schema, unless the folder holds `.graphql` files already |
| `graphql.config.yml` | IDE configuration, and `.gitignore` entries for the [IDE helper](getting-started.md#ide-support) files |

| Option | Effect |
| --- | --- |
| `--schema=ApiSchema` | Name of the schema constant (default `AppSchema`) |
| `--sdl-folder=app/schema` | Where the `.graphql` files live (default `graphql`); sets `config.sdl_folder` |
| `--skip-controller` | No controller or route (graphql-ruby's are removed too) — for apps that serve GraphQL themselves |
| `--skip-ide` | No `graphql.config.yml` or `.gitignore` entries |
| `--force` | Replace a schema class or controller the app had before |

Rerunning it is safe: a file the app has is kept, and the route and `.gitignore`
entries are added once. In an app that already had a graphql-ruby schema class or
controller, those are kept (Lighthouse replaces only what graphql-ruby wrote in the
same run), and graphql-ruby's install points that schema at the root types it
wrote: have the controller call `AppSchema.execute(...)` to serve Lighthouse's
schema, or pass `--force`.

## Lighthouse's generators

For the classes graphql-ruby has no generator for, or none that fits an SDL-first
schema. Each writes into the first namespace configured for its kind (or
`--namespace=…`); namespaced names nest modules (`Blog::Publish`).

| Generator | Writes |
| --- | --- |
| `lighthouse:query LatestPosts` | `Resolvers::LatestPosts < BaseResolver`, which `Query.latestPosts` resolves to by convention |
| `lighthouse:mutation PublishPost` | `Mutations::PublishPost < BaseMutation`, for `Mutation.publishPost` |
| `lighthouse:subscription PostUpdated` | `Subscriptions::PostUpdated < BaseSubscription`, with its hooks (and the base, when missing) |
| `lighthouse:builder Published` | `Builders::Published`, for `@builder(class: "Published")` |
| `lighthouse:validator CreatePostInput` | `Validators::CreatePostInputValidator`, a `Dry::Validation::Contract` |

The class's arguments and return type are the SDL's, so it declares neither. When
the base class is missing (an app that never ran an install, or a namespace of its
own such as `Api::Resolvers`), the generator says so: `lighthouse:install` writes it
through graphql-ruby, or write `Api::Resolvers::BaseResolver` yourself.

## graphql-ruby's generators in a Lighthouse app

| Generator | In a Lighthouse app |
| --- | --- |
| `graphql:install` | Run by `lighthouse:install`. On its own, it writes a code-first schema, root types and a `RelayClassicMutation` base: run `lighthouse:install` instead |
| `graphql:object Post` | **Use it** for a [type class](resolvers.md#type-classes): add `include Lighthouse::GraphQL::Type`, then methods. The `field` lines it writes (from the model's columns, when there is one) are ignored, as the SDL declares the fields: delete them |
| `graphql:scalar DateTime` | **Use it** for a [scalar](types.md#scalars): add `include Lighthouse::GraphQL::Type`; its `coerce_input` / `coerce_result` are the ones Lighthouse calls |
| `graphql:union SearchResult`, `graphql:interface Authored` | **Use them** when the [default resolution](types.md#the-default) is not enough: add `include Lighthouse::GraphQL::Type` and a `resolve_type`. Its `possible_types` and `field` lines are ignored |
| `graphql:enum`, `graphql:input` | Not needed: the SDL declares enums and inputs ([`@enum`](directives.md#enum) gives a value an internal one) |
| `graphql:mutation`, `graphql:mutation_create` / `_update` / `_delete` | **Not ready**: they add a field to `Types::MutationType`, which a Lighthouse app has none of (they write it again), and write a `RelayClassicMutation` taking `input:`. Use `lighthouse:mutation`, or [`@create`, `@update`, `@delete`](mutations.md) |
| `graphql:relay` | Not needed: [`@node`, `@globalId`](relay.md) and `@paginate(type: CONNECTION)` |
| `graphql:loader` | A GraphQL::Batch loader, which your own resolver classes may use; Lighthouse's directives batch through graphql-ruby's Dataloader instead |
| `graphql:detailed_trace` | **Not ready**: it edits a `class AppSchema < GraphQL::Schema`, which Lighthouse's `AppSchema = get_schema(...)` is not. Add its migration and `AppSchema.use(GraphQL::Tracing::DetailedTrace)` by hand |
