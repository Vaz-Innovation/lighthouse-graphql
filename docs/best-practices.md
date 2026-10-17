# Best Practices

A few conventions that keep a Lighthouse schema clean and predictable. They build
on the [GraphQL best practices](https://graphql-rules.com/) and PHP Lighthouse's
guidance, adapted to Rails.

## Name your primary key `id`

Clients and tooling (and Apollo Federation) assume an `id` field. Keep it `ID!`.

## Let the schema be the source of truth

Reach for a directive before writing a resolver class. Most fields are an `@all`,
`@find`, `@paginate`, a relationship, or a plain attribute read. Hand-write Ruby
(`@field`) only for genuinely custom logic. Your `.graphql` files should read like
documentation of your API.

## Keep the camelCase ↔ snake_case mapping implicit

Expose `camelCase` fields and let the default reader map them to `snake_case`
attributes. Only use `@rename(attribute:)` when the mapping isn't a plain
`underscore` — don't sprinkle it everywhere.

## Restrict filterable columns

When using `@whereConditions`, always pass `columns:` (or `columnsEnum:`) to
constrain what clients can filter on. Open-ended column filtering is a performance
and security risk:

```graphql
people(where: _ @whereConditions(columns: ["age", "type"])): [Person!]! @all
```

The same applies to `@orderBy` — expose a bounded set of sortable columns.

## Enable the Dataloader

Add `use GraphQL::Dataloader` to your schema so relationship directives batch.
Without it, nested relationships re-introduce N+1 queries.

## Authorize at the field, early

Use `@guard` and the `@can*` directives on fields that require them. They wrap the
resolver, so the check runs before any data is loaded (only `@canResolved`, which
needs the result, runs after — keep it to fields that don't write).

## Keep queries, mutations and builders apart

A custom `Query` field is a `GraphQL::Schema::Resolver` in `app/graphql/queries`,
a `Mutation` field a `GraphQL::Schema::Mutation` in `app/graphql/mutations`, and a
query refinement a builder in `app/graphql/builders`. They have different jobs and
contracts; don't fold them into one "resolvers" folder. See [resolvers.md](resolvers.md).

## Validate in the model first

Model validations already cover `@create` / `@update`. Reach for `@validator` only
for rules that aren't the model's. See [validation.md](validation.md).

## Mutations: prefer throwable errors

For mutations, raise `GraphQL::ExecutionError` for business failures ("Not
found", validation messages) rather than returning an `errors` field in the
payload. Thrown errors surface in the response's top-level `errors` array, which
is where GraphQL clients' error handling already looks — `onError` callbacks fire,
and you don't have to thread an `errors` field through every payload and caller.

```ruby
def resolve(id:)
  record = Model.find_by(id: id)
  raise GraphQL::ExecutionError, 'Not found.' unless record
  # ...
  { record: record }
end
```

## One configuration seam

Keep all Lighthouse wiring — `namespaces`, `resolver_namespaces`, custom directive
registration, federation reference resolvers, `on_error` — in initializers, not
scattered through the app. This keeps the library a clean dependency and makes the
app's GraphQL setup easy to find.

## Split your SDL

Lighthouse concatenates every `*.graphql` file under your `sdl_folder`. Organize
by domain (`users.graphql`, `orders.graphql`, …) and keep a small
`_directives.graphql` only for directives you declare yourself (built-ins are
injected automatically).
