# Configuration

Configure Lighthouse from a single initializer. Keeping app-specific wiring here
means the library holds no app constants — which is what makes it cleanly
reusable and publishable.

```ruby
# config/initializers/lighthouse.rb
require 'lighthouse-graphql'

Lighthouse.configure do |config|
  config.schema_path = Rails.root.join('graphql/schema.graphql').to_s
  config.namespaces = { queries: ['Resolvers'], mutations: ['Mutations'] }
  config.resolver_namespaces = ['App::Graphql']
  config.on_error = ->(error, _context) { Rails.error.report(error) }
end
```

## Options

### `schema_path`

The schema's entrypoint, as PHP Lighthouse's `schema_path`. Lighthouse reads
this file and the files it imports (`#import user.graphql`, `#import blog/*.graphql`).
A type is defined once, and other files add to it with `extend type`. See
[schema-organisation.md](schema-organisation.md). Defaults to
`RAILS_ROOT/graphql/schema.graphql` in a Rails app, and `nil` otherwise. Outside
Rails, pass the path, or the SDL itself (`SchemaFactory.build_base_schema(sdl:)`).

`get_schema(schema_path: ...)` overrides it for one schema.

### `ide_helper`

Rewrite `schema-directives.graphql` and `programmatic-types.graphql` in the
app's root on boot and on every reload, for the IDE
([schema-organisation.md](schema-organisation.md#ide-support)). A file whose
content is unchanged is left alone. `nil` (the default) turns it on in
development when the app has a `graphql.config.yml`, which `lighthouse:install`
writes. Set `true` or `false` to decide yourself.

### `schema_log`

Log what development learns of the schema on boot and on every reload: it built (in
how long, how big, what the reload added and removed, the files it wrote), or why it
did not, and the persisted operations it no longer accepts:

```text
[Lighthouse] ✓ AppSchema built in 61 ms: 47 types, 16 queries, 9 mutations, 3 subscriptions
[Lighthouse]   + User.nickname   − Post.legacyTitle
[Lighthouse]   wrote schema.graphql

[Lighthouse] ✗ The schema does not build: Lighthouse::DefinitionError
[Lighthouse]   No directive found for `@can` on User.nickname.
[Lighthouse]   The next GraphQL request raises it: save a fix to reload.
```

The schema is checked as `bin/rails lighthouse:validate_schema` checks it (the
`ValidateSchema` event, then every type), through the Rails logger, in colour when
`config.colorize_logging` is on. `nil` (the default) logs in a development server,
not in rake tasks or the console; `true` or `false` decide.

### `schema_output`

A file development keeps the schema clients see in, for a codegen to read, as
NestJS's `autoSchemaFile`: rewritten on boot and on every reload, and only when it
changed, so a watcher runs only then ([`schema_log`](#schema-log) says when it did). A path under the app's root, whose extension
picks the format (`.json` for the introspection result, else SDL), or a Hash naming
the schema class too (`<App>Schema`, graphql-ruby's install's name, by default):

```ruby
config.schema_output = 'schema.graphql'
config.schema_output = { path: 'app/javascript/graphql/schema.json', schema: 'Admin::Schema' }
```

Commit the file and check it in CI with `bin/rails lighthouse:schema_output:verify`,
which fails when it is out of date; `bin/rails lighthouse:print_schema WRITE=1`
rewrites it. See [printing the schema](getting-started.md#the-schema-clients-see).

### `namespaces`

Where each kind of class a schema names is looked up, by kind — they have
different contracts, so they live apart ([resolvers.md](resolvers.md)):

| Kind | Default | Holds |
| --- | --- | --- |
| `queries` | `['Resolvers']` | `Resolvers::BaseResolver` classes (a `GraphQL::Schema::Resolver`) for `Query` fields. `['Queries']` before 0.4.0 |
| `mutations` | `['Mutations']` | `Mutations::BaseMutation` classes (a `GraphQL::Schema::Mutation`) for `Mutation` fields |
| `builders` | `['Builders']` | `@builder` classes |
| `validators` | `['Validators']` | `@validator` contracts |
| `events` | `['Events']` | Classes `@event(dispatch:)` names ([events.md](events.md)) |
| `subscriptions` | `['Subscriptions']` | `Subscriptions::BaseSubscription` classes (a `GraphQL::Schema::Subscription`; the base includes `Lighthouse::GraphQL::Subscription`) for `Subscription` fields, and `@subscription(class:)` ([subscriptions.md](subscriptions.md)) |
| `analyzers` | `['Analyzers']` | `GraphQL::Analysis::Analyzer` classes (optionally including `Lighthouse::GraphQL::ComplexityAnalyzer`) that `@complexity(resolver:)` names ([security.md](security.md)) |
| `types` | `['Types']` | `Types::<Name>Type` classes including `Lighthouse::GraphQL::Type`: an object type's, whose methods resolve the fields of the SDL type `<Name>` ([resolvers.md](resolvers.md#type-classes)); a union's or interface's, which picks its values' types; a scalar's, which coerces its values ([types.md](types.md)). Also where `@union`, `@interface` and `@scalar` look classes up |

```ruby
config.namespaces = { queries: ['Api::Resolvers'] }   # the other kinds keep their defaults
```

### `resolver_namespaces`

An ordered list of namespaces tried for **models** named by a directive
(`@all(model: "User")`) and for `@field(resolver:)` on types other than `Query`
and `Mutation`, after the resolvers namespace
([resolvers.md](resolvers.md#fields-of-other-types)). Fully-qualified names
(containing `::`) are used as-is. Defaults to `['App::Graphql']`.

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

### `pagination_default_count`, `pagination_max_count`

Defaults for paginated fields: the `first` used when a client leaves it out (so
it is no longer required), and the largest `first` allowed. A directive's
`defaultCount` / `maxCount` override them; `maxCount: null` lifts the cap.

```ruby
config.pagination_default_count = 25
config.pagination_max_count = 100
```

### `schema_cache`, `schema_cache_path`, `watch_sdl`, `persisted_queries*`

Options for large schemas and high traffic, all off by default. See
[performance.md](performance.md).

```ruby
config.schema_cache = Rails.env.production?            # cache the built schema in tmp/cache
config.watch_sdl = Rails.env.development?              # reload when a .graphql file changes
config.persisted_queries = true                        # Apollo's Automatic Persisted Queries
config.persisted_queries_store = Rails.cache           # where APQ keeps queries (default: Rails.cache)
config.persisted_queries_ttl = 1.week.to_i             # how long they live there
config.persisted_queries_manifest = Rails.root.join('persisted-queries.json')  # trusted operations
config.persisted_queries_only = Rails.env.production?  # run nothing else
```

### `convert_empty_strings_to_null`

Makes every field behave as if it carried
[`@convertEmptyStringsToNull`](directives.md#convertemptystringstonull): empty
strings sent for nullable inputs arrive as `nil`, non-null inputs unchanged.
Defaults to `false`. It is read when the schema is built, so set it in the
initializer.

```ruby
config.convert_empty_strings_to_null = true
```

### `global_id`

Encodes and decodes Relay global ids for [`@globalId` and `@node`](relay.md): any
object with `encode(type, id)` returning the global id, and `decode(global_id)`
returning `[type, id]`. Defaults to `Lighthouse::GraphQL::GlobalId`, the base64 of
`Type:id`, as PHP Lighthouse's.

```ruby
config.global_id = SignedGlobalIds
```

### `queue_broadcasts`, `broadcast_queue`

Whether [`@broadcast`](directives.md#broadcast) triggers its subscription in an
ActiveJob (`Lighthouse::GraphQL::BroadcastJob`, needs the `activejob` gem)
instead of inside the mutation's request, and the queue it goes to. A directive's
`shouldQueue:` overrides `queue_broadcasts`. Defaults: `false`, and `nil` (the
default queue of ActiveJob). See [subscriptions.md](subscriptions.md#queueing).

```ruby
config.queue_broadcasts = true
config.broadcast_queue = :subscriptions
```

### `transactional_mutations`

Whether `@create` / `@update` / `@createMany` / `@updateMany` run in a database
transaction. Defaults to `true`.

### `soft_deletes`

What "trashed" means, for `@softDeletes`, `@trashed`, `@restore`, `@forceDelete`
and `@withoutGlobalScopes`. By default each model is inspected: paranoia
(`acts_as_paranoid`), then discard (`Discard::Model`), then a `deleted_at` column.
Set it for another column, or a scheme of your own:

```ruby
# Another column, for models without a gem:
config.soft_deletes = Lighthouse::Support::SoftDeletes::Column.new(:archived_at)

# Any object answering these (relations in, relations out; records in, truthy out):
class SoftDeleteAdapter
  def soft_deletes?(model) = model.include?(Archivable)
  def only_trashed(relation) = relation.unscope(where: :archived_at).where.not(archived_at: nil)
  def with_trashed(relation) = relation.unscope(where: :archived_at)
  def without_trashed(relation) = relation.unscope(where: :archived_at).where(archived_at: nil)
  def restore(record) = record.unarchive
  def force_delete(record) = record.destroy
end
config.soft_deletes = SoftDeleteAdapter.new
```

See [Soft deletes & global scopes](directives.md#soft-deletes-global-scopes).

### `authenticated_user`, `policy_user`, `authorizer`

The authentication and authorization seams behind `@guard` and the `@can*`
family. The authorizer is `->(user, record, ability, args = [])`, Pundit by
default. See [authorization.md](authorization.md#configuration).

### `feature_checker`, `feature_actor`

The seams behind [`@feature`](directives.md#feature). The checker is
`->(name, actor, ctx) { true/false }`, called with the feature's name as written
in the SDL; by default it asks Flipper, `Flipper.enabled?(name.to_sym, actor)`,
and raises a clear error when Flipper is not loaded. The actor is
`->(ctx) { actor }`; by default it is the authenticated user (a Flipper actor
answers `flipper_id`), and `nil` checks the feature globally.

```ruby
Lighthouse.configure do |config|
  config.feature_actor = ->(ctx) { ctx[:current_account] }
  config.feature_checker = ->(name, account, _ctx) { account&.features&.include?(name) }
end
```

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
