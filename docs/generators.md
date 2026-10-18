# Generators

Lighthouse builds on graphql-ruby, and so do its generators: it writes only what
graphql-ruby has no generator for, or what an SDL-first schema needs differently.
Every graphql-ruby app's schema class and base classes (`Types::BaseObject`,
`Resolvers::BaseResolver`, `Mutations::BaseMutation`, ...) come from graphql-ruby's
own `graphql:install`, and `lighthouse:install` builds on them.

## `lighthouse:install`

```shell
bin/rails generate graphql:install     # graphql-ruby's, with the options you choose
bin/rails generate lighthouse:install
```

It works on what graphql-ruby's `graphql:install` wrote, with whichever of its
options the app chose (`--relay`, the default, `--batch`, `--skip-mutation-root-type`,
`--schema`, `--directory`, `--api`, ...). When the app has no graphql-ruby schema
class yet, it runs `graphql:install` first, with graphql-ruby's defaults (and
`--api` when `config.api_only = true`). Then it adapts what graphql-ruby wrote:

| File | What Lighthouse does |
| --- | --- |
| `app/graphql/app_schema.rb` | `class AppSchema < GraphQL::Schema` becomes `class AppSchema < Lighthouse::GraphQL::RbLightHouse.get_schema(options: { base_types: { ... } })`, naming every class graphql-ruby wrote. The rest of the class stays, but the `query(...)` / `mutation(...)` lines (the SDL's root types are built on those classes) and the `resolve_type` stub (Lighthouse resolves types). With `--batch`, `use GraphQL::Dataloader` goes beside `use GraphQL::Batch`, as Lighthouse's directives batch through the Dataloader |
| `app/graphql/types/query_type.rb`, `mutation_type.rb` | The example `test_field` goes. Relay's `node` / `nodes` stay: the SDL's `Query` is built on `Types::QueryType`, so its `field`s are the schema's too |
| `app/graphql/types/base_object.rb`, `base_interface.rb`, `base_union.rb`, `base_scalar.rb` | `include Lighthouse::GraphQL::Type`: every type class inheriting from them is Lighthouse's, `Types::QueryType` and `Types::NodeType` included |
| `app/graphql/mutations/base_mutation.rb` | Kept as graphql-ruby wrote it, a `RelayClassicMutation` (see [resolvers.md](resolvers.md#resolution-by-convention)) |
| `app/controllers/graphql_controller.rb` | Replaced by one including `Lighthouse::GraphQL::Controller` (`lighthouse_schema AppSchema`), when it is still as graphql-ruby wrote it. One the app changed is kept, and the install says how to serve the schema |

And it adds Lighthouse's own:

| File | What it is |
| --- | --- |
| `config/initializers/lighthouse.rb` | Every [configuration](configuration.md) option, commented out |
| `graphql/schema.graphql` | A starter schema, unless the folder holds `.graphql` files already |
| `graphql.config.yml` | IDE configuration, and `.gitignore` entries for the [IDE helper](getting-started.md#ide-support) files |
| `app/graphql/subscriptions/base_subscription.rb` | With `--subscriptions` only: graphql-ruby has no subscription base. It includes `Lighthouse::GraphQL::Subscription` |
| `config/routes.rb` | `post "/graphql", to: "graphql#execute"`, when missing |

| Option | Effect |
| --- | --- |
| `--schema=ApiSchema` | Which graphql-ruby schema class to adopt, and its name when `graphql:install` has to run |
| `--schema-path=app/schema/schema.graphql` | The schema's entrypoint, which imports the other `.graphql` files (default `graphql/schema.graphql`); sets `config.schema_path` |
| `--subscriptions` | Write `Subscriptions::BaseSubscription` and name it in `base_types` |
| `--skip-controller` | Leave graphql-ruby's controller as it is, and add no route — for apps that serve GraphQL themselves |
| `--skip-ide` | No `graphql.config.yml` or `.gitignore` entries |

Rerunning it changes nothing: a schema class that is Lighthouse's already, a file
the app has, the route and the `.gitignore` entries are left as they are.

## Lighthouse's generators

For the classes graphql-ruby has no generator for, or none that fits an SDL-first
schema. Each writes into the first namespace configured for its kind (or
`--namespace=…`); namespaced names nest modules (`Blog::Publish`).

| Generator | Writes |
| --- | --- |
| `lighthouse:subscription PostUpdated` | `Subscriptions::PostUpdated < BaseSubscription`, with its hooks (and the base, when missing) |
| `lighthouse:builder Published` | `Builders::Published`, for `@builder(class: "Published")` |
| `lighthouse:validator CreatePostInput` | `Validators::CreatePostInputValidator`, a `Dry::Validation::Contract` |

A subscription's arguments and return type are the SDL's, so the class declares
neither. When `Subscriptions::BaseSubscription` is missing, `lighthouse:subscription`
writes it.

A resolver or mutation class has no Lighthouse generator: write a
`Resolvers::BaseResolver` subclass by hand (see [resolvers.md](resolvers.md)), add a
method to `Types::QueryType`, or run graphql-ruby's `graphql:mutation`.

## graphql-ruby's generators in a Lighthouse app

| Generator | In a Lighthouse app |
| --- | --- |
| `graphql:install` | The base `lighthouse:install` builds on: run it first with the options you want, or let `lighthouse:install` run it with its defaults |
| `graphql:object Post` | **Use it** for a [type class](resolvers.md#type-classes): it inherits from `Types::BaseObject`, so it is Lighthouse's; add methods. The `field` lines it writes (from the model's columns, when there is one) are ignored, as the SDL declares the fields: delete them |
| `graphql:scalar DateTime` | **Use it** for a [scalar](types.md#scalars): its `coerce_input` / `coerce_result` are the ones Lighthouse calls |
| `graphql:union SearchResult`, `graphql:interface Authored` | **Use them** when the [default resolution](types.md#the-default) is not enough: add a `resolve_type`. Their `possible_types` and `field` lines are ignored |
| `graphql:enum`, `graphql:input` | Not needed: the SDL declares enums and inputs ([`@enum`](directives.md#enum) gives a value an internal one) |
| `graphql:mutation PublishPost` | **Use it** for a code-first mutation: it writes `Mutations::PublishPost` and adds `field :publish_post, mutation: Mutations::PublishPost` to `Types::MutationType`, which the SDL's `Mutation` is built on. The class declares its own arguments and fields, as in graphql-ruby |
| `graphql:mutation_create` / `_update` / `_delete` | Code-first mutations like `graphql:mutation`'s, whose payload and input are code-first types (`Types::PostType`, `Types::PostInputType`). For a type the SDL declares, use [`@create`, `@update`, `@delete`](mutations.md) |
| `graphql:relay` | Run by `graphql:install` (`--relay` is its default). On an app installed with `--no-relay`, it adds `Types::NodeType`, `node` / `nodes` and the schema's `id_from_object` / `object_from_id`: add `node: Types::NodeType` to `base_types` by hand. See [relay.md](relay.md#relay-through-graphql-ruby) |
| `graphql:loader` | A GraphQL::Batch loader, which your own resolver classes may use; Lighthouse's directives batch through graphql-ruby's Dataloader instead |
| `graphql:detailed_trace` | **Not ready**: it looks for `class AppSchema < GraphQL::Schema`, which a Lighthouse schema class (`< Lighthouse::GraphQL::RbLightHouse.get_schema(...)`) does not match, and stops. Add `use GraphQL::Tracing::DetailedTrace` and `def self.detailed_trace?(query)` to the class body by hand, with graphql-ruby's migration (or `redis:`) |
