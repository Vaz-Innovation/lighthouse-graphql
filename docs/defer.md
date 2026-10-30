# Deferred fields: @defer and @stream

**Experimental: not enabled by default, not guaranteed to be stable.**

Deferring fields lets a client get the data it needs to render the most important content as
fast as possible, and the rest in the background, in later parts of the same response.
Lighthouse supports `@defer` (and `@stream`) through a plugin of the schema, as PHP Lighthouse
does through a service provider, but as the
[specification draft](https://github.com/graphql/graphql-spec/pull/1110) (RFC stage 2) has them:
`@defer` goes on a fragment, not on a field.

```graphql
query Feed {
  posts(first: 10) {
    data {
      title
      ... @defer(label: "details") { author { name } comments { data { body } } }
    }
  }
}
```

The draft can still change, and the plugin, the settings and the payloads may change with it
before it reaches stage 3.

## Setup

Use the plugin in the schema class, as PHP Lighthouse registers its `DeferServiceProvider`:

```ruby
# app/graphql/app_schema.rb
class AppSchema < Lighthouse::GraphQL::RbLightHouse.get_schema(options: { ... })
  use GraphQL::Dataloader
  use Lighthouse::GraphQL::Defer          # adds @defer and @stream
end
```

That is all. The `GraphqlController` that `rails generate lighthouse:install` writes includes
`Lighthouse::GraphQL::Controller`, which streams the response of an operation that defers, from
the same action and the same routes, `POST` and `GET` alike: no controller nor route of its own.

Without the plugin the schema has no `@defer`, as the specification asks of a server that does
not implement it. The plugin needs graphql-ruby 2.5.23 or newer (`use` raises otherwise).

## When the response streams

As in PHP Lighthouse, the response is streamed when the operation defers something: a fragment
or a list is pending once the first pass has run. One that defers nothing (no `@defer`, or one
with `if: false`) is answered as JSON, as without the plugin.

Lighthouse streams to any client, as PHP Lighthouse does, but one whose `Accept` header leaves
`multipart/mixed` out: no media range covers it (`application/json` alone), or the most specific
one that does is at `q=0` (`multipart/mixed;q=0`). That client gets the whole response at once, the
deferred fragments in it, as the specification allows. A client that sends no `Accept` header, or
`*/*`, is streamed to.

The format is the specification draft's (below), or Apollo's older one when the client's
preferred `multipart/mixed` range names it (`multipart/mixed;deferSpec=20220824`):

| The client sends | It gets |
| --- | --- |
| no `Accept`, `*/*`, `multipart/mixed` (GraphiQL: `application/json, multipart/mixed`) | the draft's format, `multipart/mixed; boundary="-"` |
| `multipart/mixed;incrementalSpec=v0.2` | the draft's format, `multipart/mixed; boundary="-"; incrementalSpec=v0.2` |
| `multipart/mixed;deferSpec=20220824` (Apollo Client 3) | Apollo's older format, `multipart/mixed; boundary="-"; deferSpec=20220824` |
| `application/json`, `application/graphql-response+json` only | the whole response, as JSON |

`Lighthouse::GraphQL::Defer.stream_type(accept)` answers the Content-Type a header gets, or nil.

Some requests are always answered whole: a batch (a JSON array of operations), which answers one
JSON array, and a `HEAD` request, which has no body. A multipart upload's operation streams as
any other.

## Configuration

Two settings keep a deferred response from running too long, PHP Lighthouse's
`defer.max_nested_fields` and `defer.max_execution_ms`, with their meaning. `0`, the default, is
no limit.

```ruby
Lighthouse.configure do |config|
  config.defer_max_nested_fields = 3       # rounds of nested deferred fragments
  config.defer_max_execution_ms = 2_000    # since the first pass started
end
```

A response goes in rounds: the first payload, then one payload for each round, which resolves
every fragment pending and announces the fragments those hold. Past `defer_max_nested_fields`
rounds, or once `defer_max_execution_ms` milliseconds have gone, the round that runs is the last:
it resolves the fragments it holds where they stand, without deferring them. See
[configuration.md](configuration.md#defer_max_nested_fields-and-defer_max_execution_ms).

## Writing @defer

`@defer` goes on an inline fragment or a fragment spread (`...Details @defer`), with `if` (defer
only when true; a variable is fine) and `label` (names the fragment in the response):

```graphql
directive @defer(if: Boolean! = true, label: String) on FRAGMENT_SPREAD | INLINE_FRAGMENT
```

To defer one field, as PHP Lighthouse's `field @defer { ... }` does, put it in a fragment of its
own: `... @defer { field { ... } }`. Fragments nest: one inside a deferred fragment arrives a round
after it.

The rules, from the draft and PHP Lighthouse. They hold for every query of the schema, streamed or
not (a graphql-ruby analyzer checks them before anything runs, and a query that breaks one is
answered the errors, without data):

- `@defer` is not allowed on a root mutation field, whose fields must run one after the other:
  "The @defer directive cannot be used on a root mutation field.", whether the fragment is inline or
  named. A fragment deeper in a mutation's response defers as in a query.
- In a subscription, `@defer` must be disabled: `if: false`, or a variable that is false for the
  request (one that is true is refused, as the draft forbids incremental delivery there).
- `label` is a string, not a variable, and no two `@defer` or `@stream` of the document share one
  (in any of its operations and fragments).
- `@skip` and `@include` on the fragment answer first: a fragment they leave out is neither
  deferred nor resolved.
- A fragment with `if` not false is always deferred, and completes. A field it selects that the
  rest of the query also asks for at the same path (itself, or through an inline or a named
  fragment) comes in the first payload as usual, resolved once, and is not sent again: in
  `{ ...UserWithParent ... @defer { parent { name } } }`, where `UserWithParent` also selects
  `parent { name }`, the fragment is pending, then completes with no data of its own. A fragment
  that adds selections to such a field (`... @defer { parent { email } }`) gets them, without
  `parent` resolving again, at the `subPath` of `parent`. Two fragments of a round that select
  one field send it once, as the draft's grouped field sets do (below).
- A fragment on a type the object does not have runs nowhere, and one on a union with no type
  condition runs where it stands, as the specification has it.

## What the client gets

The first part is the response without the deferred fragments, and a `pending` entry for each
one, with a string `id`, the `path` of the object it will run on and its `label`. A fragment under
a list is pending once for each item. Then a part for each round: the `incremental` data of each
fragment, under its `id`, and the ids that are `completed`, with the `pending` entries of the
fragments that round found; the last part has `hasNext: false`.

```json
{ "data": { "posts": { "data": [{ "title": "Hello" }] } },
  "pending": [{ "id": "0", "path": ["posts", "data", 0], "label": "details" }], "hasNext": true }
{ "incremental": [{ "id": "0", "data": { "author": { "name": "Ana" }, "comments": { "data": [] } } }],
  "completed": [{ "id": "0" }], "hasNext": false }
```

An entry carries what was not sent yet, and is one grouped field set of the draft: the fields that
the same fragments of a round select at a path. Of `... @defer(label: "a") { name loud } ...
@defer(label: "b") { loud id }`, `name` is a's, `id` is b's, and `loud` is sent once, for both,
under the first one's `id`; below an object field two fragments select differently, the fields are
grouped the same way, the object field coming first in an entry of its own. What a fragment adds to
an object field already sent comes in an entry of its own, at the field's `subPath` from the
fragment's path:

```json
{ "data": { "user": { "parent": { "name": "Ana" } } },
  "pending": [{ "id": "0", "path": ["user"] }], "hasNext": true }
{ "incremental": [{ "id": "0", "data": { "name": "Bo" } },
                  { "id": "0", "subPath": ["parent"], "data": { "email": "ana@example.com" } }],
  "completed": [{ "id": "0" }], "hasNext": false }
```

The errors of a deferred field come with it, on its `incremental` entry, with the path the field
has in the response. A fragment's delivery is all or nothing: when a non-null field fails beyond
any part of it (its object, or an object it adds to at a `subPath`), it sends no data at all, and
its `id` is `completed` with the `errors`; the fragments it holds are not announced. A field it
shares with another fragment fails that one too, as the draft has it, but a field of its own does
not: the other fragment sends its fields all the same. A field a fragment that failed had resolved
resolves again for a later fragment that selects it (its value was never sent). The `extensions` that `BuildExtensionsResponse` and
`ManipulateResult` listeners add while a fragment runs are on its `incremental` entry too; an entry
that would carry nothing else (no data, no errors) is not sent, and its extensions go on the
part's own `extensions`, as those of a fragment that sends no data.

### Apollo's older format

A client that names `deferSpec=20220824` gets the payloads in the format graphql-js 17.0.0-alpha.2
answered, which Apollo Client 3 and Apollo Client 4's `Defer20220824Handler` read. The fragments,
their rounds and their data are the same; only the payloads are written another way:

- The first payload has no `pending`.
- An `incremental` entry has a `path` instead of an `id`: the path of the fragment's object, and
  the `subPath` after it, with the fragment's `label`. A stream's `items` come at the path of the
  list and the index of the first item (`["users", 1]` after `initialCount: 1`).
- There is no `completed`. A fragment that failed sends `data: null` with its `errors` (a stream,
  `items: null`); one that completes with nothing of its own to send (the response already holds
  it) sends `data: {}` at its path, so that the client hears of each fragment.

```json
{ "data": { "posts": { "data": [{ "title": "Hello" }] } }, "hasNext": true }
{ "incremental": [{ "data": { "author": { "name": "Ana" }, "comments": { "data": [] } },
                    "path": ["posts", "data", 0], "label": "details" }], "hasNext": false }
```

## Streaming lists (experimental)

`@stream` on a list field answers its first `initialCount` items (default 0) at once, and the
others in a later part. PHP Lighthouse has no `@stream`.

```graphql
directive @stream(if: Boolean! = true, label: String, initialCount: Int! = 0) on FIELD

query { posts(first: 50) { data @stream(initialCount: 5, label: "rest") { title } } }
```

```json
{ "data": { "posts": { "data": [ ... 5 items ... ] } },
  "pending": [{ "id": "0", "path": ["posts", "data"], "label": "rest" }], "hasNext": true }
{ "incremental": [{ "id": "0", "items": [ ... 45 items ... ] }], "completed": [{ "id": "0" }], "hasNext": false }
```

The field's resolver runs once and returns the whole list; `@stream` cuts it where `initialCount`
says, and the items that follow run in the next round, all together so the Dataloader batches
across them: as graphql-ruby completes the list, on the field's object (under a type condition on
an interface or a union too), the field answered with those items and its resolver not run. A list of scalars streams too, and so does a paginated field's
`data`. A list that resolves to `null` is `null`, and so is a `null` item where the list's items
may be; where they may not, a `null` item (or one a non-null field's error nulls) fails the
stream, which completes with the error, the items already sent staying. An item may carry `@defer`: its fragment is
announced with the items, at the index the item has in the list, and arrives after them. The rest
of a list is one batch: the specification allows a server to cut it as it pleases. The later items
run what every declaration of the field selects (`users @stream { id } ... on Query { users { name }
}`), and nothing of another field of the same name. Where that depends on more than the field's
object (a declaration under a type condition above it, or in another deferred fragment, or the
streamed field itself in a named fragment spread both inside a deferred fragment and outside), the
list is answered whole.

`@stream` needs a list field (a validation error otherwise), follows the rules of `@defer` for
`label`, mutations ("The @stream directive cannot be used on a root mutation field.") and
subscriptions, and a negative `initialCount` is a field error: the field is `null`, with the error at
its path. The plugin adds a graphql-ruby trace module to the schema that uses it (and no other
schema built on the same types), which cuts the lists of every field of that schema, whenever the
field was defined, and changes no field; a field that is not streamed costs it a method call and
two fiber-local reads (the @stream mark, then whether a streamed response runs), and a lazy one a
fiber-local read more when its value syncs.

## Clients

- **GraphiQL** (`GraphiQL.createFetcher`, as the example app's `/graphiql`) reads the draft's
  format: a query with `@defer` shows the deferred fields as they arrive.
- **Apollo Client 4** reads either, with the handler of its format: `GraphQL17Alpha9Handler` (the
  draft's) or `Defer20220824Handler` (the older one), as its `incrementalHandler`.
- **Apollo Client 3** sends `multipart/mixed;deferSpec=20220824` and gets the older format.
- **graphql-js 17** and **Relay** read the draft's format.

A client that cannot read `multipart/mixed` should leave it out of its `Accept` header
(`application/json`), and gets the whole response.

## Transport

The response is the body Rails streams from the action, as it streams a template
(`self.response_body =`, the parts of a `multipart/mixed` body, graphql-over-http's incremental
delivery): the server writes each part as its round has run, in the request's thread, inside its
executor (the database connection, `ActiveSupport::CurrentAttributes` and the query cache are the
request's, as for any action). No thread of its own, as `ActionController::Live` would start. A
part's JSON is encoded as `render json:` encodes any response.

Streaming needs a server that writes the body as it goes (Puma; not a single-threaded buffering
one), sending it chunked, and proxies that do not buffer: the response sends `X-Accel-Buffering: no`
for nginx, `Cache-Control: no-store`, so no cache keeps it, and a `Last-Modified` so `Rack::ETag`
lets it through. Do not put `Rack::Deflater` in front of it. `@cacheControl` does not apply to a
streamed response.

The first part is encoded in the action, so that an error there (a value of the app's that does
not encode) is answered as on the JSON path, through the controller's `rescue_from`, nothing being
sent. Once the action returns, the response is on its way and can no longer be refused: a
`@throttle` past its limit in a later round is the field's error ("Rate limit for Query.x exceeded.
Try again later."), and its `with:` method is not called. A round that fails, or a part that cannot
be encoded, ends the stream all the same, with a last part that completes, with an error, every id
the client was sent and has not seen completed, and the closing boundary. The error goes to
`Rails.error` (`handled: true`, `severity: :error`) and the log, and not to the controller's
`rescue_from` handlers, which could not render on a response already on its way. An error
writing the closing boundary is reported after it. A client that goes away (the server cannot
write a part) ends the stream quietly: nothing more is written or reported.

## How it runs

- **The client's document, as it came.** It is never rewritten: validation, analysis, listeners
  (`StartExecution#query`), `query.query_string`, the operation's fingerprint and tracing see the
  document the client sent, streamed or not. graphql-ruby hands `@defer` its arguments, not its node;
  Lighthouse knows the node by the arguments graphql-ruby caches for it.
- **Every field resolves once.** The first pass leaves the deferred fragments out; each round
  then runs the pending fragments on the objects the passes before it loaded
  (`GraphQL::Query::Partial`), never by running their parents again, and leaves out what the
  response already holds. `@throttle`, `@guard`, `@cache`, events and the rest of a field's
  directives run in the pass that resolves the field; a mutation does not run twice. To reach an
  object field the response already holds, the plugin's trace module keeps, while a streamed
  response runs, the objects its fragments will need, in whatever trace mode the app picks. An app
  that gives a trace class of its own, leaving out the schema's trace modules, gets every response
  whole.
- **No N+1.** The fragments of a round run together, in one multiplex, so the Dataloader batches
  across them: a deferred fragment under a list of 50 costs the queries it costs without `@defer`.
  When two fragments select different fields of an object field neither was sent, that field
  resolves first and the fields below it in a second multiplex of the same round (a pass), each
  batched in turn.
- **The schema's `execute`.** The first pass is the schema's `execute`, as on the JSON path: an
  app's own `AppSchema.execute` (instrumentation, a tenant in the context, a default context) runs
  for a streamed request too, and the query is the schema's `query_class`. An `execute` that runs
  the query without the context it was given, or answers no `GraphQL::Query::Result`, gets the
  response whole. The rounds are not operations, and do not go through `execute`: they run their
  `GraphQL::Query::Partial`s through `schema.multiplex` (which an override of `multiplex` sees),
  with the first pass's context. To act on every part of a streamed response, use a graphql-ruby
  trace module (`trace_with`) or Lighthouse's execution events, which see the rounds too.
  Partials run on graphql-ruby's standard execution engine; its new one (2.6's
  `GraphQL::Execution::Next`) is not supported.
- **Validation and complexity cover the whole document**, before the first pass: the deferred
  fragments count for `max_complexity` and `max_depth`, as they would without `@defer`.
- **Events.** `StartExecution` and `EndExecution` fire for the first pass, and again for each unit a
  round runs (the fragments of one path on its object, or a stream's items), with the client's
  document; `EndOperationOrOperations` after the closing boundary, and `EndRequest` last, once the
  response is out ([events.md](events.md)).

## Testing

`Lighthouse::GraphQL::Testing#stream_graphql`, PHP Lighthouse's `streamGraphQL`, posts a query
that defers and answers its payloads, in order ([testing.md](testing.md)):

```ruby
it 'defers the details' do
  initial, later = stream_graphql('{ posts(first: 1) { data { title ... @defer { author { name } } } } }')

  expect(initial['pending'].size).to eq(1)
  expect(later['completed']).to eq([{ 'id' => '0' }])
end
```

## Differences from PHP Lighthouse

- **Fragments, not fields.** PHP Lighthouse's `@defer` goes on a field (`directive @defer(if:
  Boolean = true) on FIELD`); the draft's, and this one, on a fragment, with a `label`. A query
  written for PHP Lighthouse puts each deferred field in a fragment: `parent @defer { name }`
  becomes `... @defer { parent { name } }`.
- **The draft's format, or Apollo's, not the 2018 one.** PHP Lighthouse answers `null` for a
  deferred field first, then chunks keyed by path (`{ "user.parent": { "data": ... } }`) and no
  `hasNext`. This leaves the field out of the first payload, and answers `pending`, `incremental`,
  `completed` and `hasNext`, or Apollo's `deferSpec=20220824` format to a client that names it,
  which today's clients read.
- **A client can say it does not stream.** PHP Lighthouse streams whatever the client accepts; this
  answers the whole response to a client whose `Accept` header leaves `multipart/mixed` out.
- **One pass per round, not the query again.** PHP Lighthouse runs the whole operation again for
  each round, and answers what it already has from the previous result; this runs only the deferred
  fragments, on the objects already loaded. A field resolves once, and a mutation runs once.
- **`@stream` is added.** PHP Lighthouse has none.
- **A field asked for outside the fragment too is sent once, and the fragment still completes.**
  PHP Lighthouse (as Apollo) does not defer a field one of whose declarations is not deferred: the
  field, with everything any declaration selects of it, comes in the first payload. As the draft
  has it, the fragment here is deferred all the same: the field comes in the first payload with
  what the rest of the query selects of it, the fragment sends what it adds, and completes.
- **Non-null fields can be deferred.** PHP Lighthouse refuses `@defer` on a Non-Null field ("The
  @defer directive cannot be used on a Non-Nullable field.") because it answers `null` for it first;
  the draft's format leaves the field out instead, so nothing needs refusing.
- **The rules hold for every query.** PHP Lighthouse checks them as a deferred field resolves; here
  they are checked before anything runs, for every request, streamed or not.
- **The time limit counts milliseconds from the first pass.** `defer_max_execution_ms` starts when
  the first pass does; PHP Lighthouse's deadline is set when its `Defer` is built, as
  `microtime(true) + max_execution_ms * 1000`, a time in seconds plus the setting times a thousand
  (2000 reads as two million seconds).
