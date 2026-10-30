# Events

Lighthouse dispatches events as a request goes by and as the schema is built, so
an app can hook into them without patching either. They mirror
[PHP Lighthouse's events](https://lighthouse-php.com/master/api-reference/events.html),
adapted to Ruby: a listener is a block or anything that responds to `call(event)`.

```ruby
# config/initializers/lighthouse.rb
Lighthouse::Events.listen(Lighthouse::Events::StartExecution) do |event|
  Rails.logger.info("GraphQL #{event.operation_name} at #{event.moment}")
end
```

## Listening

```ruby
listener = Lighthouse::Events.listen(Lighthouse::Events::EndExecution) { |event| Metrics.record(event.result) }
Lighthouse::Events.listen(Lighthouse::Events::EndRequest, AuditLog)   # anything with #call
Lighthouse::Events.forget(listener)                                    # stop listening
```

- Listeners run in registration order. A listener on an event class also hears
  its subclasses, so one on `Lighthouse::Events::Event` hears everything.
- `Lighthouse::Events.dispatch(event)` returns the non-nil values the listeners
  returned. Some events give them a meaning (below); for the others they are
  ignored, so a listener's last expression does no harm.
- Register in an initializer. Specs can call `Lighthouse::Events.reset!` to drop
  every listener.

### ActiveSupport::Notifications

Every dispatch is also instrumented as `<event name>.lighthouse`, with the event
as the `:event` payload, so Rails tooling observes them with no listener of ours:

```ruby
ActiveSupport::Notifications.subscribe('end_execution.lighthouse') do |*, payload|
  Rails.logger.info(payload[:event].result['errors'])
end
```

The name is the class name underscored: `start_request.lighthouse`,
`build_schema_string.lighthouse`, ...

## Request lifecycle

In the order they happen. Events with a `moment` carry the `Time` they were
created at (UTC).

| Event | When | Readers |
| --- | --- | --- |
| `StartRequest` | The controller action begins | `request`, `moment` |
| `StartOperationOrOperations` | The operation(s) were read, before they run | `operation_or_operations` |
| `StartExecution` | A query is about to run (once per operation of a batch) | `schema`, `query`, `variables`, `operation_name`, `context`, `graphql_query`, `moment` |
| `BuildExtensionsResponse` | A query ran | `result`, `query_complexity` |
| `ManipulateResult` | Before the result is returned | `result` (+ writer) |
| `EndExecution` | The result is final | `result`, `operation_name`, `context`, `graphql_query`, `moment` |
| `EndOperationOrOperations` | The operation(s) ran | `result_or_results` |
| `EndRequest` | The response is rendered | `response`, `moment` |

`StartRequest` and `EndRequest` are dispatched by `execute`, the action of the
`Lighthouse::GraphQL::Controller` concern that `rails g lighthouse:install`
generates a controller with ([getting-started.md](getting-started.md)):
the first thing it does, and right after it renders. An action of your own gets
them by wrapping its body in `lighthouse_request`, which dispatches them once
however it nests:

```ruby
def search
  lighthouse_request do
    render json: Lighthouse::GraphQL::PersistedQueries.execute(AppSchema, query: params[:q])
  end
end
```

Without the concern, dispatch them yourself:
`Lighthouse::Events.dispatch(Lighthouse::Events::StartRequest.new(request))`, and
`EndRequest.new(response)` after rendering.

`StartOperationOrOperations` and `EndOperationOrOperations` are dispatched by
`Lighthouse::GraphQL::PersistedQueries.execute`, which the generated controller
calls. The first carries a Hash (`query`, `variables`, `operation_name`,
`extensions`), as the request named them. For a batch, run the operations through
`PersistedQueries.multiplex(schema, operations, context: ...)` instead (the concern does for a JSON array body): it takes
an Array of such Hashes (each may also carry its own `context`), dispatches the
Arrays, and answers one result per operation. Operations that run straight on
`schema.execute` or `schema.multiplex` fire only the execution events below.

### Execution events

`StartExecution`, `BuildExtensionsResponse`, `ManipulateResult` and
`EndExecution` come from a graphql-ruby trace Lighthouse installs on every schema
it builds, so they fire however the query was started: the controller,
`schema.execute` in a job, or a spec. A multiplex fires them once per query.
With no listener, and no `ActiveSupport::Notifications` subscriber, they cost
one lookup per request.

A fragment deferred with [`@defer`](performance.md#deferring-fields-experimental) runs in a
multiplex of its own after the first response: the events fire again for each object it runs on,
with the operation's `query`, `variables` and `operation_name`, and the result of that fragment.

`StartExecution#query` is the parsed `GraphQL::Language::Nodes::Document`, and
`operation_name` the one the client gave. Both events carry the `GraphQL::Query` as
`graphql_query`, and `EndExecution` its `operation_name` (the operation that ran,
`nil` for an anonymous one) and `context`. In a batch, graphql-ruby runs the
operations together, so every `StartExecution` comes before any `EndExecution`:
read what you need from `EndExecution`, or pair the two by `graphql_query`, not by
order. PHP Lighthouse's `EndExecution` has the result only, as it runs a batch's
operations one after the other.

```ruby
Lighthouse::Events.listen(Lighthouse::Events::EndExecution) do |event|
  errors = event.result['errors']
  Rails.logger.warn("GraphQL #{event.operation_name || 'an anonymous operation'} answered with errors") if errors.present?
end
```

**`BuildExtensionsResponse`**: return an `ExtensionsResponse` (or an Array of
them) to add to the result's `extensions`:

```ruby
Lighthouse::Events.listen(Lighthouse::Events::BuildExtensionsResponse) do |event|
  Lighthouse::Events::ExtensionsResponse.new('queries', Query.count_for(event.result))
end
# => { "data" => {...}, "extensions" => { "queries" => 3 } }
```

`query_complexity` is the query's complexity score, the number graphql-ruby
checks against `max_complexity` (see [security.md](security.md#reading-the-score)).
It is `nil` for a query that failed validation.

**`ManipulateResult`**: change `event.result` (the Hash with `data`, `errors` and
`extensions`) in place, or assign a new Hash to `event.result=`:

```ruby
Lighthouse::Events.listen(Lighthouse::Events::ManipulateResult) do |event|
  event.result['extensions'] = (event.result['extensions'] || {}).merge('served_by' => Socket.gethostname)
  nil
end
```

Both also fire for a query that fails validation; the result then holds `errors`
and no `data`.

## Schema build events

These fire while the schema is built, once per build. Listen from an initializer
that runs before the schema is first used (the schema constant autoloads when
something first refers to it).

**`RegisterDirectiveNamespaces`**: return a namespace (a `Module`, or its name)
or an Array of them. Every directive class under them (a constant that responds
to `directive_name`: a field resolver or an argument builder) is registered, as
if with `Lighthouse::DirectiveRegistry.register`:

```ruby
Lighthouse::Events.listen(Lighthouse::Events::RegisterDirectiveNamespaces) do
  %w[App::Graphql::Directives MyEngine::Directives]
end
```

A name that is no constant fails the build with `Lighthouse::DefinitionError`.
It fires before the directive definitions are injected, on every build,
schema cache or not.

**`BuildSchemaString`**: return SDL to append to the app's schema, before the
manipulation phase (so it can use any directive):

```ruby
Lighthouse::Events.listen(Lighthouse::Events::BuildSchemaString) do |event|
  'extend type Query { version: String @field(resolver: "Version") }'
end
```

**`ManipulateAST`**: the document after manipulation, right before the schema
is built from it. graphql-ruby's nodes are immutable, so replace the document:
`event.document_ast = GraphQL.parse(...)`.

With [`schema_cache`](performance.md#schema-cache) on, these two fire only when the document
is actually built, on a cache miss, and the cache holds what they made. The cache
key does not cover them: after you change what a listener adds, run
`bin/rails lighthouse:clear_cache`.

## `ValidateSchema`

`bin/rails lighthouse:validate_schema` (`SCHEMA=AppSchema` names another schema)
dispatches `ValidateSchema` with the schema, then has graphql-ruby build and print
every type. A listener that raises, or a schema graphql-ruby rejects, aborts the
task with a message, so it can run in CI:

```ruby
Lighthouse::Events.listen(Lighthouse::Events::ValidateSchema) do |event|
  raise 'The schema has no mutations' unless event.schema.mutation
end
```

## Dispatching your own: `@event`

The [`@event`](directives.md#event) directive dispatches an event of yours once a
field has resolved:

```graphql
type Mutation {
  publishPost(id: ID!): Post! @update @event(dispatch: "PostPublished")
}
```

```ruby
# app/events/post_published.rb
class PostPublished
  attr_reader :post

  def initialize(post) = @post = post
end

Lighthouse::Events.listen(PostPublished) { |event| Mailer.published(event.post).deliver_later }
```

Any class works as an event. Lighthouse looks the name up in
`Config.namespaces[:events]` (default `['Events']`, so `Events::PostPublished`,
then `::PostPublished`).
