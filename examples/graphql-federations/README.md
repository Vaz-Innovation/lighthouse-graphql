# Lighthouse federated example

The blog of [`../graphql`](../graphql), split into two
[Apollo Federation](https://www.apollographql.com/docs/federation/) subgraphs, each a
Rails 8.1 app running Lighthouse from this checkout, behind
[Apollo Router](https://www.apollographql.com/docs/graphos/routing), and behind
[GraphQL Yoga](https://the-guild.dev/graphql/yoga-server) ([`gateway/`](gateway)). It is:

- **An example** of a federated graph written the Lighthouse way: each subgraph's
  schema is SDL with directives, which links the Federation spec and says what
  each field does; Ruby only where there is real logic.
- **An end-to-end suite** (`spec/`): it starts PostgreSQL, both subgraphs and the
  router, composes the supergraph from what the subgraphs answer, and drives
  every feature through the router, and the graph through Yoga as well.

## The subgraphs

| | [`accounts/`](accounts) | [`blog/`](blog) |
| --- | --- | --- |
| Owns | `User`, likes, avatars | `Post`, `Comment`, `Tag` |
| Schema | [`accounts/graphql/schema.graphql`](accounts/graphql/schema.graphql) | [`blog/graphql/schema.graphql`](blog/graphql/schema.graphql) |
| Database | its own | its own, and accounts' read-only (Rails' multiple databases), for tokens and authors |

How they meet:

- **`User`** is accounts' entity, by two keys (`@key(fields: "id") @key(fields: "email")`).
  The blog adds what users wrote: `posts` (`@hasMany`), `postsCount` (which it took
  over from accounts with `@override`), `comments` (a connection) and `signature`,
  which `@requires` the `name` accounts holds. `Post.author` and `Comment.author`
  are `@belongsTo` in the blog, and the router fetches the rest from accounts;
  `Comment.author` `@provides` the name, sparing it the fetch.
- **`Authored`** is an entity interface of the blog (`Post` and `Comment`, with UUID
  keys, unique across both tables). Accounts extends it as an `@interfaceObject`
  with `likesCount` and `likedBy`, and its `like` mutation answers one: the router
  asks the blog which type it is.
- **`ReadingTime`** is an entity by its post's id, resolved by its type class's
  `resolve_references`, so the router can fill `caption`'s argument from the post it
  belongs to (`@context` / `@fromContext`).
- **`Tag`** is a Relay node whose key is its global id (`@node`, `@globalId`).
- Subscriptions are the blog's: the router subscribes with an HTTP callback
  (`Lighthouse::GraphQL::Federation::CallbackSubscriptions`), Yoga over
  Server-Sent Events, and both resolve the accounts fields of every update. One
  broadcast reaches both, and any Action Cable channel.
- The rest is Lighthouse's, in whichever subgraph it belongs to: `@paginate`
  (paginators and connections, whose generated types are `@shareable`),
  `@whereConditions`, `@orderBy`, `@search`, `@cache`/`@clearCache`, `@guard` and
  the `@can*` directives (the router passes the `Authorization` header on),
  `@validator`, nested mutations, `@upload` and `@attachment`, `@throttle`, `@count`,
  `@method`, convention resolvers and mutations, and type classes. Plus `@tag`,
  `@inaccessible`, `@cost`/`@listSize` and a directive of the app's own kept in
  the supergraph with `@composeDirective`.

[`router/`](router) holds the router's configuration ([`router.yaml`](router/router.yaml)),
each subgraph's SDL as Lighthouse prints it, and the supergraph rover composes from them.

## The Yoga gateway

[`gateway/`](gateway) is a Node app: [GraphQL Yoga](https://the-guild.dev/graphql/yoga-server)
serving the supergraph as [`@graphql-tools/federation`](https://the-guild.dev/graphql/hive/docs/gateway)
stitches it. Each subgraph is reached through `@graphql-tools/executor-http`:
queries and mutations as POSTs, subscriptions as a GET that accepts
`text/event-stream`, which Lighthouse answers over Server-Sent Events. Its
clients subscribe to it over SSE too (graphql-sse), with no license.

`@graphql-tools/federation` does not plan `@interfaceObject`:
[`gateway/src/interface-objects.js`](gateway/src/interface-objects.js) adds it,
joining `Post` and `Comment` to accounts on `Authored`'s key and sending accounts
`Authored` representations. It does not run contexts either: `caption` gets no
`postTitle` through Yoga (`@fromContext`), and the blog answers without it. The
rest (entities, `@requires`, `@provides`, `@override`, unions, nodes,
`@inaccessible`, the `Authorization` header passed on) is as through the router.

```shell
cd gateway && npm ci
SUBGRAPH_URLS='{"accounts":"http://localhost:3001/graphql","blog":"http://localhost:3002/graphql"}' npm start
```

It reads `router/supergraph.graphql` (`SUPERGRAPH` another), and listens on `PORT` (4100).

## Running the suite

It needs Docker (the router, and PostgreSQL through Testcontainers),
[rover](https://www.apollographql.com/docs/rover/getting-started) to compose the
supergraph (without it, the suite uses `router/supergraph.graphql` as it is), and
Node 20 for the Yoga gateway (without it, `spec/yoga/` is skipped; the suite runs
`npm ci` in `gateway/` the first time).

```shell
bundle install
bundle exec rspec
```

`PGHOST` (with `PGPORT`, `PGUSER`, `PGPASSWORD`) uses your PostgreSQL instead of a
container; `ROUTER_IMAGE` another router image. Each server's log is in `tmp/`.

Subscriptions and batching are GraphOS features of the router: it starts with
them only when connected to GraphOS, so the suite turns them on, and runs their
specs, only when `APOLLO_KEY` and `APOLLO_GRAPH_REF` name a graph (a free plan's
will do). Without them, the blog's side of the callback protocol is still
checked, with the spec playing the router.

After changing a subgraph's schema, `bin/compose` prints both SDLs into
`router/` and composes the supergraph again; the suite fails while they are out of date.

## Running it by hand

```shell
(cd accounts && bin/rails db:prepare && bin/rails server -p 3001)
(cd blog && bin/rails db:prepare && bin/rails server -p 3002)
docker run --rm -p 4000:4000 --add-host host.docker.internal:host-gateway \
  -v "$PWD/router:/config" ghcr.io/apollographql/router:v2.19.0 \
  --config /config/router.yaml --supergraph /config/supergraph.graphql
```

`router/supergraph.yaml` routes to `localhost:3001` and `localhost:3002`; from
the container, set `override_subgraph_url` to `host.docker.internal` in a copy
of `router.yaml` (and drop its `subscription` and `batching` without GraphOS).
