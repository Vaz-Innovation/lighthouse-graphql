# Example app

A small blog API built with Lighthouse on Rails 8.1. It does two jobs:

- **An example.** It shows what a real app looks like: an SDL-first schema, a
  little Ruby where there is real logic, Pundit policies and opt-in performance
  features.
- **The end-to-end suite.** Its specs drive the real `POST /graphql` and
  `GET /graphql` endpoints through the gem in `..`, so a change to the library
  is tested the way an app uses it.

## Running it

```shell
cd example
bin/setup --skip-server      # bundle install + database
bin/rails db:seed            # sample users, posts and tags; prints two API tokens
bin/rails server
```

In development, **GraphiQL** is at <http://localhost:3000/graphiql>. It has the schema
docs (including the types Lighthouse generates) and a query explorer. To sign in,
paste a token from `db:seed` into its Headers tab:
`{ "Authorization": "Bearer <token>" }`.

Or with curl:

```shell
curl -s localhost:3000/graphql -H 'Content-Type: application/json' \
  -d '{"query":"{ posts(first: 5) { data { title author { name } tags { name } tagsCount excerpt(length: 40) } paginatorInfo { total } } }"}'

curl -s localhost:3000/graphql -H 'Content-Type: application/json' -H 'Authorization: Bearer <token from db:seed>' \
  -d '{"query":"mutation { createPost(input: { title: \"Hello\", tags: { connect: [1], create: [{ name: \"new\" }] } }) { id tags { name } } }"}'
```

Run the end-to-end suite with `bundle exec rspec`, or `bin/ci`, which also
checks `persisted-queries.json` against the schema.

It runs on SQLite by default. `DATABASE_URL` runs it on PostgreSQL or MySQL, and
`REDIS_URL` adds a Redis cache store to the `@throttle` specs, as CI does:

```shell
docker run -d -p 5433:5432 -e POSTGRES_PASSWORD=postgres postgres:16
docker run -d -p 3307:3306 -e MYSQL_ROOT_PASSWORD=root mysql:8.4
docker run -d -p 6380:6379 redis:7

export REDIS_URL=redis://127.0.0.1:6380/0 RAILS_ENV=test
DATABASE_URL=postgres://postgres:postgres@127.0.0.1:5433/lighthouse_example_test bin/rails db:create db:schema:load
DATABASE_URL=postgres://postgres:postgres@127.0.0.1:5433/lighthouse_example_test bundle exec rspec
DATABASE_URL=trilogy://root:root@127.0.0.1:3307/lighthouse_example_test bin/rails db:create db:schema:load
DATABASE_URL=trilogy://root:root@127.0.0.1:3307/lighthouse_example_test bundle exec rspec
```

`@async` mutations run in Solid Queue, whose tables are in the app's database: start
a worker with `bin/jobs` next to `bin/rails server`.

## Where things are

| What | Where |
| --- | --- |
| The schema, split by domain: [`schema.graphql`](graphql/schema.graphql) defines the root types and `#import`s the others, which add their fields with `extend type Query` / `extend type Mutation` | [`graphql/`](graphql) |
| Lighthouse's configuration | [`config/initializers/lighthouse.rb`](config/initializers/lighthouse.rb) |
| The schema class: graphql-ruby's, built by Lighthouse from the SDL on graphql-ruby's root types and base classes | [`app/graphql/app_schema.rb`](app/graphql/app_schema.rb) |
| The endpoint (`current_user` in the context, `Cache-Control`) | [`app/controllers/graphql_controller.rb`](app/controllers/graphql_controller.rb) |
| GraphiQL, routed in development only | [`app/controllers/graphiql_controller.rb`](app/controllers/graphiql_controller.rb), [`app/views/graphiql/show.html.erb`](app/views/graphiql/show.html.erb) |
| Query fields resolved by convention (`Query.searchPosts` → `Resolvers::SearchPosts`, a `Resolvers::BaseResolver`) | [`app/graphql/resolvers/`](app/graphql/resolvers) |
| Fields resolved by the class `@field` names: on Query (`popularTags` → `Resolvers::Tags::Popular`), and on Post, where `object` is the post (`tagsCount` → `Resolvers::Posts::TagsCount`, `excerpt(length:)` → `Resolvers::Posts::Excerpt`) | [`app/graphql/resolvers/tags/`](app/graphql/resolvers/tags), [`app/graphql/resolvers/posts/`](app/graphql/resolvers/posts) |
| Mutations resolved by convention (`Mutation.publishPost` → `Mutations::PublishPost`, a `Mutations::BaseMutation`, graphql-ruby's `RelayClassicMutation`, called with the SDL's arguments as keywords) | [`app/graphql/mutations/`](app/graphql/mutations) |
| Subscriptions resolved by convention (`Subscription.postCreated` → `Subscriptions::PostCreated`), each a `Subscriptions::BaseSubscription`, which includes the Lighthouse concern: `filter?` hooks, or graphql-ruby's own `authorized?`/`update` | [`app/graphql/subscriptions/`](app/graphql/subscriptions) |
| The ActionCable socket: `GraphqlChannel` runs the operations, `Connection` identifies `current_user` by the API token | [`app/channels/`](app/channels), [`config/cable.yml`](config/cable.yml) |
| Type classes, in graphql-ruby's structure, Lighthouse's through their base (`Types::BaseObject` and `Types::BaseScalar` include `Lighthouse::GraphQL::Type`): `Post.readingTime` → `Types::PostType#reading_time` (`model Post`), the fields of `ReadingTime`, which is not a model, → `Types::ReadingTimeType`, and the `DateTime` scalar → `Types::DateTimeType` (a `Types::BaseScalar`). The `SearchResult` union and `Authored` interface need no class: each record resolves to its model's type | [`app/graphql/types/`](app/graphql/types) |
| `@builder` classes | [`app/graphql/builders/`](app/graphql/builders) |
| `@validator` contracts (Dry::Validation) | [`app/graphql/validators/`](app/graphql/validators) |
| Policies behind `@canFind`, `@canModel`, `@canRoot` | [`app/policies/`](app/policies) |
| Trusted operations, served by hash | [`persisted-queries.json`](persisted-queries.json) |

The setup was generated by running both installs, as an app would:

```shell
bin/rails g graphql:install --schema=AppSchema --api
bin/rails g lighthouse:install --subscriptions
```

graphql-ruby's install wrote the schema class, the root types (`Types::QueryType`
with Relay's `node` / `nodes`, `Types::MutationType`), `Types::NodeType`, the base
classes and the controller; Lighthouse's adapted them. The app then added its own
settings: ActionCable subscriptions and `max_complexity` in the schema class body,
the controller's `rate_limit` and `graphql_context`, and the initializer's schema
cache and persisted queries. The subscriptions, builders and validators come from
`bin/rails g lighthouse:subscription`, `:builder` and `:validator`, the type classes
from graphql-ruby's `graphql:object` and `graphql:scalar`. The resolvers and
mutations are plain graphql-ruby classes, which no generator writes. As in a graphql-ruby app, resolvers, mutations and
subscriptions inherit from their namespace's base class (`Resolvers::BaseResolver`,
`Mutations::BaseMutation`, `Subscriptions::BaseSubscription`), where what they all
share goes: the subscriptions' concern is included there, once.

Ids are graphql-ruby's: `AppSchema.id_from_object` / `object_from_id`, on Rails'
GlobalID, as its install wrote them. `Tag.id @globalId` answers `tag.to_gid_param`,
and `Query.node` / `nodes` are `Types::QueryType`'s.

## What the specs cover

| Spec | Lighthouse features |
| --- | --- |
| [`requests/graphql/queries_spec.rb`](spec/requests/graphql/queries_spec.rb) | `@find`, `@paginate` (paginator and Relay connection), `@like`, `@orderBy` (columns, a relation's COUNT, and on a field), `@whereConditions`, `@whereHasConditions`, `@builder`, `scopes:`, `@count`, a `Resolvers::` class |
| [`requests/graphql/cursor_connection_spec.rb`](spec/requests/graphql/cursor_connection_spec.rb) | Relay cursor pagination on a relationship (`User.comments`, `@hasMany(type: CONNECTION)`): `pageInfo`, `after`, and a client loop that walks every page |
| [`requests/graphql/field_resolvers_spec.rb`](spec/requests/graphql/field_resolvers_spec.rb) | `@field(resolver:)`: on `Post`, the class receives the post as `object`, in a paginated list, on a single post, under `me`; field arguments with an SDL default; `tagsCount` batched through the dataloader (no N+1); on `Query`, a nested name looked up in the resolvers namespace |
| [`requests/graphql/real_backends_spec.rb`](spec/requests/graphql/real_backends_spec.rb) | What depends on the real backends: `@whereJsonContains` on the database's JSON (SQLite, PostgreSQL, MySQL), `@async` queued in Solid Queue and run by a real worker (and nothing queued when `@canFind` refuses), `@throttle` counting per IP and user in a file store and in Redis, across two clients of the same store |
| [`requests/graphql/uploads_spec.rb`](spec/requests/graphql/uploads_spec.rb) | A multipart request (the GraphQL multipart request specification) to `Mutation.updateAvatar`: `@upload` stores the file with ActiveStorage under `avatars/`, `@update` attaches it; a guest's call stores nothing |
| [`requests/graphql/relay_and_eager_loading_spec.rb`](spec/requests/graphql/relay_and_eager_loading_spec.rb) | `@node` and `@globalId` on graphql-ruby's Relay (`Tag` ids from `AppSchema.id_from_object`, `Query.node` from `Types::QueryType`); `@withCount` (`Tag.usage`, one COUNT for every tag), `@with` (`User.latestPostTitle`) and `@lazyLoad` (`User.posts` with their tags), with no N+1; `@field(resolver: "Statistics@counts")`; `resolve_info.enhance_builder` in `Resolvers::MyPosts` |
| [`requests/graphql/types_spec.rb`](spec/requests/graphql/types_spec.rb) | A union (`Query.search`: `Post` and `User` records) and an interface (`Query.latestActivity`: `Authored`, implemented by `Post` and `Comment`) resolved to each record's type by default; the `DateTime` scalar's `Types::DateTimeType` writing ISO 8601 and reading an argument as a `Time`, refusing one it cannot read; `@method` passing a field's argument to `Post#summary` |
| [`requests/graphql/type_classes_spec.rb`](spec/requests/graphql/type_classes_spec.rb) | Type classes: `Types::PostType#reading_time` resolves `Post.readingTime`, `Types::ReadingTimeType#minutes(words_per_minute:)` a field of a type that is not a model, beside fields read off the model and resolved by directives and `@field` |
| [`requests/graphql/relationships_spec.rb`](spec/requests/graphql/relationships_spec.rb) | `@belongsTo`, `@hasMany` (paginated too), `@belongsToMany`, `@count(relation:)`, and no N+1: the number of SQL queries does not grow with the number of records |
| [`requests/graphql/authorization_spec.rb`](spec/requests/graphql/authorization_spec.rb) | `@guard`, `@canRoot`, `@canFind` with Pundit |
| [`requests/graphql/mutations_spec.rb`](spec/requests/graphql/mutations_spec.rb) | `@create`, `@update`, `@delete`, `@validator`, model validation errors, nested mutations (`connect`, `create`, `sync`) with rollback, `@inject`, `@rename`, a `Mutations::` class |
| [`requests/graphql/caching_spec.rb`](spec/requests/graphql/caching_spec.rb) | `@cacheControl` headers, `@cache` and `@clearCache` |
| [`requests/graphql/complexity_spec.rb`](spec/requests/graphql/complexity_spec.rb) | `AppSchema.max_complexity`: an expensive query is refused before it runs; paginated fields scale by `first`, `@complexity(resolver:)` naming `Analyzers::TagPostsComplexity` (an `Analyzers::BaseComplexity`) on `Tag.posts`, the `complexity` `Resolvers::SearchPosts` declares, `BuildExtensionsResponse#query_complexity` |
| [`requests/graphql/persisted_queries_spec.rb`](spec/requests/graphql/persisted_queries_spec.rb) | Automatic persisted queries over POST and GET (with `Cache-Control` and `ETag`), the trusted-operations manifest |
| [`channels/graphql_channel_spec.rb`](spec/channels/graphql_channel_spec.rb), [`channels/application_cable/connection_spec.rb`](spec/channels/application_cable/connection_spec.rb) | `GraphqlChannel` with ActionCable's test helpers: a subscription is registered and streamed, a guest is refused by `authorized?`, unsubscribing deletes it; the connection's token |
| [`subscriptions/delivery_spec.rb`](spec/subscriptions/delivery_spec.rb) | `@broadcast` end to end over ActionCable's pub/sub: `createPost` reaches the `postCreated` subscribers (drafts only their author and admins, `NO_UPDATE`), `publishPost` the `postPublished` ones for that author, `addComment` the `commentAdded` ones with no `postId` or that post's (a draft's only to its author and admins), a failed or refused mutation nothing, a closed socket stops receiving |
| [`tasks/lighthouse_tasks_spec.rb`](spec/tasks/lighthouse_tasks_spec.rb) | `lighthouse:cache`, `lighthouse:clear_cache`, `lighthouse:ide_helper`, `lighthouse:persisted_queries:verify` |
| [`graphql/app_schema_spec.rb`](spec/graphql/app_schema_spec.rb) | The types and arguments Lighthouse generates |

## Subscriptions

`graphql/schema.graphql` declares three, over ActionCable (`AppSchema`'s class body has
`use GraphQL::Subscriptions::ActionCableSubscriptions`):

- `postCreated`: broadcast by `createPost`. Signed-in users only, and a draft
  reaches only its author and admins.
- `postPublished(authorId: ID)`: broadcast by `publishPost`. Open to guests; the
  optional `authorId` narrows it to one author.
- `commentAdded(postId: ID)`: broadcast by `addComment`. Without `postId` it
  carries every new comment, with it only that post's; comments on a draft reach
  only its author and admins.

All inherit from `Subscriptions::BaseSubscription`, a `GraphQL::Schema::Subscription`
that includes the `Lighthouse::GraphQL::Subscription` concern, and show its two
styles: `PostPublished` and `CommentAdded` use the concern's field-wide topic and
`filter?`, which is what lets an optional argument narrow one trigger per
subscriber, and `PostCreated` defines graphql-ruby's own `authorized?` and `update`
(returning `NO_UPDATE`), which win over the concern's. To try them, sign in with a
token from `db:seed` (`?token=` or an `Authorization` header, as on `/graphql`), and
open a socket with [`wscat`](https://github.com/websockets/wscat):

```shell
wscat -c 'ws://localhost:3000/cable?token=<token from db:seed>' -s actioncable-v1-json
> {"command":"subscribe","identifier":"{\"channel\":\"GraphqlChannel\"}"}
> {"command":"message","identifier":"{\"channel\":\"GraphqlChannel\"}","data":"{\"action\":\"execute\",\"query\":\"subscription { postPublished { title } }\"}"}
```

then publish a draft through `POST /graphql` (`mutation { publishPost(id: 3) { id } }`)
and the update arrives on the socket. `config/cable.yml` uses the `async` adapter in
development, which keeps everything in one process; use a shared adapter in
production (see [docs/subscriptions.md](../docs/subscriptions.md)). The specs use the
`test` adapter, which is `async` underneath, so the delivery specs exercise the real
streams.

## Opt-in features this app turns on

Lighthouse leaves them off by default. Here, each one is turned on where it is
meant to be used (see the initializer):

- `config.watch_sdl` in development: edit a `.graphql` file, and the next request
  sees it, with no restart.
- `config.schema_cache` in production: run `bin/rails lighthouse:cache` at deploy
  time to warm it.
- `config.persisted_queries`, with a `GET /graphql` route, so CDNs can cache
  responses, plus `config.persisted_queries_manifest`.
