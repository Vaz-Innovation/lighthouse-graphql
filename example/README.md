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
  -d '{"query":"{ posts(first: 5) { data { title author { name } tags { name } } paginatorInfo { total } } }"}'

curl -s localhost:3000/graphql -H 'Content-Type: application/json' -H 'Authorization: Bearer <token from db:seed>' \
  -d '{"query":"mutation { createPost(input: { title: \"Hello\", tags: { connect: [1], create: [{ name: \"new\" }] } }) { id tags { name } } }"}'
```

Run the end-to-end suite with `bundle exec rspec`, or `bin/ci`, which also
checks `persisted-queries.json` against the schema.

## Where things are

| What | Where |
| --- | --- |
| The schema, split by domain | [`graphql/`](graphql) |
| Lighthouse's configuration | [`config/initializers/lighthouse.rb`](config/initializers/lighthouse.rb) |
| The endpoint (`current_user` in the context, `Cache-Control`) | [`app/controllers/graphql_controller.rb`](app/controllers/graphql_controller.rb) |
| GraphiQL, routed in development only | [`app/controllers/graphiql_controller.rb`](app/controllers/graphiql_controller.rb), [`app/views/graphiql/show.html.erb`](app/views/graphiql/show.html.erb) |
| Queries resolved by convention (`Query.searchPosts` → `Queries::SearchPosts`) | [`app/graphql/queries/`](app/graphql/queries) |
| Mutations resolved by convention (`Mutation.publishPost` → `Mutations::PublishPost`) | [`app/graphql/mutations/`](app/graphql/mutations) |
| Subscriptions resolved by convention (`Subscription.postCreated` → `Subscriptions::PostCreated`), `GraphQL::Schema::Subscription`s, plain and with the Lighthouse concern | [`app/graphql/subscriptions/`](app/graphql/subscriptions) |
| The ActionCable socket: `GraphqlChannel` runs the operations, `Connection` identifies `current_user` by the API token | [`app/channels/`](app/channels), [`config/cable.yml`](config/cable.yml) |
| `@builder` classes | [`app/graphql/builders/`](app/graphql/builders) |
| `@validator` contracts (Dry::Validation) | [`app/graphql/validators/`](app/graphql/validators) |
| Policies behind `@canFind`, `@canModel`, `@canRoot` | [`app/policies/`](app/policies) |
| Trusted operations, served by hash | [`persisted-queries.json`](persisted-queries.json) |

The classes under `app/graphql` were generated with `bin/rails g lighthouse:query`,
`:mutation`, `:builder` and `:validator`, and the setup with
`bin/rails g lighthouse:install`.

## What the specs cover

| Spec | Lighthouse features |
| --- | --- |
| [`requests/graphql/queries_spec.rb`](spec/requests/graphql/queries_spec.rb) | `@find`, `@paginate` (paginator and Relay connection), `@like`, `@orderBy`, `@whereConditions`, `@builder`, `scopes:`, `@count`, a `Queries::` class |
| [`requests/graphql/cursor_connection_spec.rb`](spec/requests/graphql/cursor_connection_spec.rb) | Relay cursor pagination on a relationship (`User.comments`, `@hasMany(type: CONNECTION)`): `pageInfo`, `after`, and a client loop that walks every page |
| [`requests/graphql/relationships_spec.rb`](spec/requests/graphql/relationships_spec.rb) | `@belongsTo`, `@hasMany` (paginated too), `@belongsToMany`, `@count(relation:)`, and no N+1: the number of SQL queries does not grow with the number of records |
| [`requests/graphql/authorization_spec.rb`](spec/requests/graphql/authorization_spec.rb) | `@guard`, `@canRoot`, `@canFind` with Pundit |
| [`requests/graphql/mutations_spec.rb`](spec/requests/graphql/mutations_spec.rb) | `@create`, `@update`, `@delete`, `@validator`, model validation errors, nested mutations (`connect`, `create`, `sync`) with rollback, `@inject`, `@rename`, a `Mutations::` class |
| [`requests/graphql/caching_spec.rb`](spec/requests/graphql/caching_spec.rb) | `@cacheControl` headers, `@cache` and `@clearCache` |
| [`requests/graphql/persisted_queries_spec.rb`](spec/requests/graphql/persisted_queries_spec.rb) | Automatic persisted queries over POST and GET (with `Cache-Control` and `ETag`), the trusted-operations manifest |
| [`channels/graphql_channel_spec.rb`](spec/channels/graphql_channel_spec.rb), [`channels/application_cable/connection_spec.rb`](spec/channels/application_cable/connection_spec.rb) | `GraphqlChannel` with ActionCable's test helpers: a subscription is registered and streamed, a guest is refused by `authorized?`, unsubscribing deletes it; the connection's token |
| [`subscriptions/delivery_spec.rb`](spec/subscriptions/delivery_spec.rb) | `@broadcast` end to end over ActionCable's pub/sub: `createPost` reaches the `postCreated` subscribers (drafts only their author and admins, `NO_UPDATE`), `publishPost` the `postPublished` ones for that author, `addComment` the `commentAdded` ones with no `postId` or that post's (a draft's only to its author and admins), a failed or refused mutation nothing, a closed socket stops receiving |
| [`tasks/lighthouse_tasks_spec.rb`](spec/tasks/lighthouse_tasks_spec.rb) | `lighthouse:cache`, `lighthouse:clear_cache`, `lighthouse:ide_helper`, `lighthouse:persisted_queries:verify` |
| [`graphql/app_schema_spec.rb`](spec/graphql/app_schema_spec.rb) | The types and arguments Lighthouse generates |

## Subscriptions

`graphql/schema.graphql` declares three, over ActionCable (`AppSchema` is built with
`GraphQL::Subscriptions::ActionCableSubscriptions`):

- `postCreated`: broadcast by `createPost`. Signed-in users only, and a draft
  reaches only its author and admins.
- `postPublished(authorId: ID)`: broadcast by `publishPost`. Open to guests; the
  optional `authorId` narrows it to one author.
- `commentAdded(postId: ID)`: broadcast by `addComment`. Without `postId` it
  carries every new comment, with it only that post's; comments on a draft reach
  only its author and admins.

All are `GraphQL::Schema::Subscription` classes, in the two styles: `PostCreated`
is plain graphql-ruby (`authorized?`, `update` returning `NO_UPDATE`), and
`PostPublished` and `CommentAdded` include the `Lighthouse::GraphQL::Subscription`
concern for PHP Lighthouse's field-wide topic and `filter?`, which is what lets an
optional argument narrow one trigger per subscriber. To try them, sign in with a
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
