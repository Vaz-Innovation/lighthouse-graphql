# Caching

Two independent layers, matching PHP Lighthouse:

- **Application cache.** `@cache` stores a field's resolved value in the Rails
  cache (`Rails.cache`), so later requests skip the resolver.
- **HTTP cache.** `@cacheControl` computes the `Cache-Control` header a response
  may carry, so browsers, CDNs and proxies can reuse it.

## `@cache`

```graphql
directive @cache(maxAge: Int, private: Boolean = false) on FIELD_DEFINITION
```

```graphql
type Query {
  highestKnownPrime: Int! @field(resolver: "Primes") @cache
  temperature: Int! @cache(maxAge: 300)
  myTodos: [Todo!]! @cache(private: true)
}
```

- **`maxAge`** is in seconds. Without it, an entry lives until `@clearCache`
  invalidates it or the store evicts it.
- **`private: true`** keeps one entry per authenticated user (by `id`). Guests
  share one.
- **The key** covers the parent type, the parent's key, the field and its
  arguments. The parent's key is the field marked `@cacheKey`, else its first
  `ID` field; root types have none.

```graphql
type GithubProfile {
  username: String @cacheKey
  repos: [Repository!]! @cache    # one entry per username
}
```

Lists and relations are stored as arrays. A value the store cannot serialize,
such as a Relay connection object, is reported through
[`on_error`](configuration.md#on_error) and returned uncached. So cache list
fields, not connection fields.

The store is your app's cache, `Rails.cache` (`config.cache_store`), as PHP
Lighthouse uses Laravel's: Lighthouse keeps no store of its own. Note that Rails
uses a `:null_store` in development and test unless you enable caching
(`bin/rails dev:cache`).

A cached value is still authorized and validated on every request: `@cache` runs
inside `@guard`, `@can*` and `@validator`, never around them.

## `@clearCache`

```graphql
directive @clearCache(type: String!, idSource: ClearCacheIdSource, field: String) repeatable on FIELD_DEFINITION

input ClearCacheIdSource {
  argument: String   # path of an argument, e.g. "input.id"
  field: String      # path in the result, e.g. "*.id"
}
```

Put it on a mutation. It invalidates entries once the mutation has resolved
successfully; a failed mutation clears nothing.

```graphql
type Mutation {
  # Every cached field of every Post.
  importPosts: Boolean @clearCache(type: "Post")

  # The cached fields of the post whose id the argument holds.
  updatePost(input: UpdatePostInput! @spread): Post! @update
    @clearCache(type: "Post", idSource: { argument: "input.id" })

  # One field of each post the mutation returned.
  retitlePosts(ids: [ID!]!, title: String!): [Post!]!
    @clearCache(type: "Post", idSource: { field: "*.id" }, field: "title")

  # A root field.
  publishPost(id: ID!): Post @clearCache(type: "Query", field: "latestPosts")
}
```

### How invalidation works

PHP Lighthouse clears entries through cache tags. Rails cache stores have no tags,
and `delete_matched` is not available everywhere (Solid Cache and Memcached lack
it). So Lighthouse **versions** keys instead:

1. Each entry's key embeds four version tokens: the type, the type and id, the
   type and field, and the type, id and field.
2. `@clearCache` replaces the token it targets, so the entries built on the old
   one are never read again. They expire or are evicted on their own.
3. If a token is evicted, a new one is written, which causes misses, never stale
   reads.

This works on any store, and clearing a type also clears its per-id entries.
Each cached read costs one `read_multi` for the tokens.

## `@cacheControl`

```graphql
directive @cacheControl(maxAge: Int = 0, scope: CacheControlScope = PUBLIC, inheritMaxAge: Boolean = false)
  on FIELD_DEFINITION | OBJECT | INTERFACE | UNION
```

Lighthouse walks the fields a query selects, fragments included, and derives one
header. These are PHP Lighthouse's rules, after Apollo's:

- `max-age` is the **lowest** `maxAge` among the contributing fields. 0 gives
  `no-cache`.
- The response is `private` if any selected field is `PRIVATE`.
- **Defaults:**
  - A root field without the directive is `maxAge: 0, PRIVATE`.
  - Any other field returning an object, interface or union is 0, unless its
    type carries `@cacheControl`.
  - Scalar fields inherit their parent and don't contribute.
  - A directive on the field overrides one on its type, and its omitted arguments
    take the directive's defaults (0, `PUBLIC`).
- `inheritMaxAge: true` takes the parent field's `maxAge`.
- Mutations are never cacheable.

```graphql
type Query {
  publicCompanies: [Company!]! @cacheControl(maxAge: 15)
  me: User! @guard @cacheControl(maxAge: 5, scope: PRIVATE)
}

type Company @cacheControl(maxAge: 40) {
  users: [User!]! @hasMany @cacheControl(maxAge: 25)
}
```

`{ publicCompanies { users { id } } }` gets `max-age=15, public`;
`{ me { id } }` gets `max-age=5, private`.

### Sending the header

The controller from `rails generate lighthouse:install` already does this:

```ruby
result = AppSchema.execute(params[:query], ...)
Lighthouse::GraphQL::CacheControl.apply(response, result)   # no-op without @cacheControl
render json: result
```

`Lighthouse::GraphQL::CacheControl.header(result)` returns the value without
setting it.

Things to know:

- Shared caches only store `GET` responses, and the generated route is
  `POST /graphql`. Add `get '/graphql', to: 'graphql#execute'` and send cacheable
  queries over `GET`, ideally as [persisted queries](performance.md#persisted-queries),
  whose hash fits in a URL.
- The pagination types Lighthouse generates (`paginatorInfo`, `data`, `pageInfo`,
  `edges`, `node`) inherit their parent field's `maxAge`, as in PHP Lighthouse,
  so a paginated field is as cacheable as its `@cacheControl` says.
- With a `public` max-age, Rack's ETag middleware adds an `ETag`, so clients can
  revalidate with `If-None-Match`.
- Rails normalizes `no-cache, private` to `no-cache`. `no-cache` already forces
  every cache to revalidate, so nothing is stored stale.
