# Configuration

Configure Lighthouse from a single initializer. Keeping app-specific wiring here
means the library holds no app constants — which is what makes it cleanly
reusable and publishable.

```ruby
# config/initializers/lighthouse.rb
require 'lighthouse-graphql'

Lighthouse.configure do |config|
  config.sdl_folder = Rails.root.join('graphql').to_s
  config.namespaces = { queries: ['Queries'], mutations: ['Mutations'] }
  config.resolver_namespaces = ['App::Graphql', 'Resolvers']
  config.on_error = ->(error, _context) { Rails.error.report(error) }
end
```

## Options

### `sdl_folder`

Where Lighthouse loads `*.graphql` files from. Defaults to `RAILS_ROOT/graphql`
in a Rails app, `nil` otherwise (pass SDL explicitly via `SchemaFactory` when not
on Rails).

### `namespaces`

Where each kind of class a schema names is looked up, by kind — they have
different contracts, so they live apart ([resolvers.md](resolvers.md)):

| Kind | Default | Holds |
| --- | --- | --- |
| `queries` | `['Queries']` | `GraphQL::Schema::Resolver` classes for `Query` fields |
| `mutations` | `['Mutations']` | `GraphQL::Schema::Mutation` classes for `Mutation` fields |
| `builders` | `['Builders']` | `@builder` classes |
| `validators` | `['Validators']` | `@validator` contracts |

```ruby
config.namespaces = { queries: ['Api::Queries'] }   # the other kinds keep their defaults
```

### `resolver_namespaces`

An ordered list of namespaces tried for **models** named by a directive
(`@all(model: "User")`) and for `@field(resolver:)` on types other than `Query`
and `Mutation`. Fully-qualified names (containing `::`) are used as-is. Defaults
to `['App::Graphql']`.

```ruby
config.resolver_namespaces = ['App::Graphql', 'Resolvers']
# "ContactPerson" tries App::Graphql::ContactPerson, then Resolvers::ContactPerson, then ::ContactPerson
```

This is the seam that keeps the gem free of your app's namespace.

### `on_error`

A callable `->(error, context) { ... }` invoked when a directive or resolver
swallows an error (e.g. a malformed filter). The default **raises in test** (so
failures surface in your suite) and logs otherwise. Point it at your error
reporter in production:

```ruby
config.on_error = ->(error, _ctx) { Sentry.capture_exception(error) }
```

### `cache_store`

The store behind [`@cache` / `@clearCache`](caching.md). Defaults to
`Rails.cache` (an in-memory store outside Rails).

```ruby
config.cache_store = ActiveSupport::Cache::RedisCacheStore.new(url: ENV['REDIS_URL'])
```

### `pagination_default_count`, `pagination_max_count`

Defaults for paginated fields: the `first` used when a client leaves it out (so
it is no longer required), and the largest `first` allowed. A directive's
`defaultCount` / `maxCount` override them; `maxCount: null` lifts the cap.

```ruby
config.pagination_default_count = 25
config.pagination_max_count = 100
```

### `transactional_mutations`

Whether `@create` / `@update` / `@createMany` / `@updateMany` run in a database
transaction. Defaults to `true`.

### `authenticated_user`, `policy_user`, `authorizer`

The authentication and authorization seams behind `@guard` and the `@can*`
family. The authorizer is `->(user, record, ability, args = [])`, Pundit by
default. See [authorization.md](authorization.md#configuration).

## Extending the registry

Register app-defined directives (see [custom-directives.md](custom-directives.md))
from the same initializer:

```ruby
Lighthouse::DirectiveRegistry.register(App::Graphql::Directives::StartsWith)
```

Directives implemented inside another class — no class of their own to
register — contribute their SDL definition with `register_definition`, so it is
injected into the schema and written by `bin/rails lighthouse:ide_helper`:

```ruby
Lighthouse::DirectiveRegistry.default.register_definition(
  'tenant', 'directive @tenant(column: String) on FIELD_DEFINITION'
)
```

Types a definition refers to (an enum argument, say) are registered with
`register_type_definition('TenantMode', 'enum TenantMode { STRICT LOOSE }')`, or
returned by the directive class's `type_definitions` (`{ name => sdl }`). They
are injected only alongside a directive that uses them, and only if the schema
doesn't define them itself.

## Federation reference resolvers

Custom federation entity resolvers are registered with
`Lighthouse::ReferenceResolver` (see [federation.md](federation.md)), typically in
`config/initializers/federation.rb` so they re-register on code reload:

```ruby
Rails.application.config.to_prepare do
  Lighthouse::ReferenceResolver.register('User') { |ref, _ctx| User.find_by(id: ref['id']) }
end
```
