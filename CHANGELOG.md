# Changelog

All notable changes to `lighthouse-graphql` are documented here. The format is
based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and this
project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `Lighthouse::GraphQL::Type`, a concern that hands a graphql-ruby type class to Lighthouse, in
  graphql-ruby's `app/graphql/types` structure. A field of an object type with no resolving
  directive resolves with the method of its snake_case name on `Types::<Type>Type`, when that class
  includes the concern and defines it (`Post.readingTime` → `Types::PostType#reading_time`). As in
  graphql-ruby, the method has `object` (the parent), `context`, the `dataload*` helpers, and the
  field's arguments as keywords. The SDL still declares the fields; the ones the class does not
  define are read off the object as before. A type class that does not include the concern is left
  alone. The class is looked up in the new `types` namespace (default `['Types']`), and must inherit
  from `base_types[:object]` when one is given.
- `@model(class:)`, as PHP Lighthouse's: maps an object type to the ActiveRecord model of another
  name. Every directive taking `model:` (`@all`, `@find`, `@paginate`, `@create`, `@update`, the
  `@can*` family...) on a field returning the type gets it, unless it names its own; unions,
  interfaces and `@node` resolve the model's records to the type; the schema does not build unless
  it is a model; and a type class's methods only run on its records (another parent is reported
  through `on_error`).
- Unions and interfaces resolve each value to its object type as PHP Lighthouse does: a Hash's
  `__typename`, else the type named after the value's class or a superclass (STI), else the type
  whose `@model` names its model. A union's type class (`Types::SearchResultType` including the
  concern) can take over with graphql-ruby's `self.resolve_type(object, context)`, an interface's
  with `definition_methods { def resolve_type }`, and `@union(resolveType:)` /
  `@interface(resolveType:)` name a class in the SDL. A value nothing resolves, or one resolved
  outside the union, raises `Lighthouse::DefinitionError` naming the ways out.
- Custom scalars read and write their values through their class: `Types::DateTimeType` (a
  `GraphQL::Schema::Scalar` including the concern), or the class `@scalar(class:)` names, with
  graphql-ruby's `coerce_input` / `coerce_result`. A `GraphQL::CoercionError` makes the argument
  invalid with its message. A scalar with no class passes its values through, as before.
- `@method` passes the field's arguments to the method: as snake_case keywords when it takes
  keywords, otherwise positionally in SDL order, as PHP Lighthouse does.
- `base_types[:union]`, `[:interface]` and `[:scalar]`, like `[:object]`, are the bases the type
  classes of their kind must inherit from.
- `docs/types.md`: unions, interfaces and scalars.
- `@field(resolver: "Class@method")`, as PHP Lighthouse's: the method replaces `call` on a plain
  class (as a class method, else an instance method), or `resolve` on a resolver class, whose
  `ready?` / `authorized?` still run.
- `ResolveInfo`, PHP Lighthouse's `$resolveInfo`: `resolve_info` in `Resolvers::` / `Mutations::`
  classes, classes `@field` names and type class methods, and a fourth argument for a plain callable
  that takes one. It has the field, its parent type, object, arguments, context and path, and
  `enhance_builder(relation, scopes: [])`, which applies the field's `@builder` classes and argument
  directives (`@eq`, `@where`, `@orderBy`, `@whereConditions`, ...) to a query the class builds.
- `@with(relation:, scopes:)` and `@withCount(relation:, scopes:)` eager-load a relation, or its
  count (kept on the parent as `<relation>_count`), before the field resolves; `@lazyLoad(relations:)`
  eager-loads relations of the records a field returns. All three load across every parent in the
  response at once, through the Dataloader, and take nested relations (`"posts.comments"`).
- Relay global object identification: `@globalId` encodes a field (base64 of `Type:id`) and decodes
  an argument or input field (`decode: ARRAY | TYPE | ID`); `@node` makes a type implement `Node` and
  adds `Query.node(id:)`, which finds the record through the type's model or `@node(resolver:)`. The
  new `global_id` setting takes your own encoder. `docs/relay.md`.
- A union's or interface's class may answer `[type, value]`, as graphql-ruby allows.
- File uploads: the `Upload` scalar (Lighthouse's own for `scalar Upload`), the GraphQL multipart
  request specification in `Lighthouse::GraphQL::Controller`, and `@upload(disk:, path:)`, which
  stores the file through the new `upload_store` setting (an ActiveStorage blob by default) and
  passes its signed id. `docs/uploads.md`.
- Filters: `@whereNull`, `@whereNotNull`, `@whereBetween`, `@whereNotBetween`, `@whereJsonContains`
  (PostgreSQL, MySQL, SQLite), `@scope`, `@nest` (the filters of an input's fields) and `@limit`
  (a LIMIT, or a per-parent cut of a relation's records); `@whereAuth(relation:)` keeps the
  signed-in user's records.
- Argument directives: `@trim`, `@drop`, `@hash` (BCrypt) and `@bind(class:)`, which replaces an id
  with its record(s) or fails validation. Rewriting ones (`@globalId`, `@trim`, `@drop`) run before
  `@guard`, `@can*` and `@validator`; effectful ones (`@hash`, `@bind`, `@upload`) after them.
- `@builder` on an argument or input field, as PHP Lighthouse's: the method gets the argument's
  value whenever the client sends it, `null` included. `method: "Class@method"` names the builder
  without `class:`, and `value:` on a field passes a fixed value in place of the arguments.
- `@limit(builder: true)` puts the LIMIT on the field's query; `@limit` must be on an `Int` argument,
  and is accepted on the field itself, as PHP Lighthouse allows.
- `@hasManyThrough` and `@hasOneThrough`, PHP Lighthouse's names, as aliases of `@hasMany` and
  `@hasOne`, which resolve `has_many` / `has_one :through`.
- `ResolveInfo#lookahead`: graphql-ruby's Lookahead for a field resolved by a class (a `Resolvers::`
  class, `@field`, a type class method). It never reaches the arguments, so `@cache` keys are unchanged.
- `@throttle` logs a warning when the cache store is a `:null_store`, which counts nothing.
- `@enum(value:)` for an enum value's internal value; `@namespaced` to group fields; `@throttle` to
  rate-limit a field per user or IP (the controller concern now puts `:remote_ip` in the context);
  `@async` to run a mutation in an ActiveJob and answer `true`; `@hide(env:)` / `@show(env:)` to leave
  fields out by environment (the schema cache key now includes it).

### Changed

- Generators build on graphql-ruby's instead of copying them. `lighthouse:install` runs
  `graphql:install --no-relay --skip-graphiql --skip-query-logs` for the base classes every
  graphql-ruby app has (`Types::Base*`, `Resolvers::BaseResolver`, `Mutations::BaseMutation`), then
  replaces what it wrote that an SDL-first app does differently: the schema class (built from the
  SDL, naming every base in `base_types`), the controller, no `Types::QueryType` /
  `MutationType`, and a `BaseMutation` that is a `GraphQL::Schema::Mutation`. It writes
  `Subscriptions::BaseSubscription` itself, graphql-ruby having none. Files the app had are kept.
- `docs/generators.md`: every generator, and which of graphql-ruby's fit a Lighthouse app
  (`graphql:object`, `:scalar`, `:union`, `:interface` for type classes; `graphql:mutation` and
  `graphql:detailed_trace` not as they are).

- `@field(resolver:)` on a field of a type other than `Query` and `Mutation` looks the class up in
  the resolvers namespace first, nested names included: `@field(resolver: "Posts::TagsCount")`
  resolves to `Resolvers::Posts::TagsCount`. Then it tries `resolver_namespaces`, as before, so
  full names and classes outside `Resolvers::` resolve as they did. A class `Resolvers::X` now
  wins over one that `resolver_namespaces` would find for the same name.

### Fixed

- A wrapping directive (`@globalId`, `@guard`, `@cache`, ...) on a field of a type whose objects are
  Hashes read nothing: the wrapped default reader only called methods. It now reads the Hash's
  keys, as the default reader does.

- A field returning a union or an interface no longer raises `undefined method 'resolve_type' for
  an instance of Proc`. Lighthouse's field dispatcher replaced the schema's default resolve with a
  Proc, which graphql-ruby also asks for `resolve_type` and scalar coercion; it now hands both on.

- `@field(resolver:)` on a `Query` or `Mutation` field finds a nested name in the resolvers /
  mutations namespaces, as documented: `"Feeds::Home"` resolves to `Resolvers::Feeds::Home`,
  then to `Feeds::Home`. It used to try only `Feeds::Home`, so the field resolved to `null`.
  The field's `complexity` is looked up the same way.

### Documentation

- `docs/resolvers.md`: fields of types other than `Query` and `Mutation` resolved with `@field`,
  whose class receives the parent record as `object`. The example app resolves `Post.tagsCount`
  (batched through the dataloader), `Post.excerpt(length:)` and `Query.popularTags` this way.
  It resolves `Post.readingTime` and the `ReadingTime` type, which is not a model, with
  `Types::PostType` and `Types::ReadingTimeType`, `Query.search` (a union of `Post` and `User`)
  and `Query.latestActivity` (an `Authored` interface) by the default, `DateTime` with
  `Types::DateTimeType`, and `Post.summary(words:)` with `@method`. `Tag` is a Relay node with
  global ids; `User.latestPostTitle` uses `@with`, `Tag.usage` `@withCount`, `User.posts`
  `@lazyLoad`, `Query.counts` `@field(resolver: "Statistics@counts")`, and `Query.myPosts`
  `resolve_info.enhance_builder`. `Mutation.updateAvatar` takes a multipart upload with `@upload`
  (the example now loads ActiveStorage). `Mutation.schedulePublish` is `@async` on Solid Queue,
  `Query.searchPosts` is `@throttle`d, and `Query.posts` filters `metadata` with `@whereJsonContains`;
  the example's suite runs on PostgreSQL and MySQL too (`DATABASE_URL`, a new CI job), with Redis.

### Removed

- `rails g lighthouse:type`: it was graphql-ruby's `graphql:object` (and `:scalar`, `:union`,
  `:interface`) with an `include`. Generate the class with graphql-ruby, then add
  `include Lighthouse::GraphQL::Type`.
- `lighthouse:query` and `lighthouse:mutation` no longer write `Resolvers::BaseResolver` /
  `Mutations::BaseMutation` when they are missing: graphql-ruby's install writes them, which
  `lighthouse:install` runs. They say so instead.

## [0.4.0] - 2026-10-17

### Added

- `@complexity` sets what a field costs in graphql-ruby's query complexity analysis, so
  `AppSchema.max_complexity(n)` refuses expensive queries before they run. A bare `@complexity`
  costs `1 + child complexity × first`. `@complexity(resolver: "Name")` names a
  `GraphQL::Analysis::Analyzer` subclass in the new `analyzers` namespace (`Analyzers::Name`),
  which Lighthouse installs on the schema. Including `Lighthouse::GraphQL::ComplexityAnalyzer`
  gives the analyzer a `complexity` (a number, or a proc of `context, args, child_complexity`,
  as graphql-ruby's) that is the cost of the fields naming it.
- A root field resolved by a `GraphQL::Schema::Resolver` class, by convention or through `@field`,
  takes the `complexity` that class declares, as graphql-ruby's `field ..., resolver:` does.
- `BuildExtensionsResponse#query_complexity` holds the query's complexity score while something
  listens to the event. It used to be `nil`.
- `docs/security.md`: query complexity, depth and introspection limits.
- graphql-ruby's base classes: `rails g lighthouse:install` writes `Resolvers::BaseResolver`,
  `Mutations::BaseMutation` and `Subscriptions::BaseSubscription` (which includes
  `Lighthouse::GraphQL::Subscription`), and `lighthouse:query`, `:mutation` and `:subscription`
  write the one they need when it is missing. Generated classes inherit from them. An existing
  base, such as the ones graphql-ruby's `graphql:install` writes, is never replaced.
- `get_schema`'s `base_types` takes `resolver:`, `mutation:` and `subscription:` beside
  graphql-ruby's own keys. Every class a `Query`, `Mutation` or `Subscription` field resolves to
  must then inherit from its kind's base (`Lighthouse::DefinitionError` otherwise), and a
  `Subscription` field with no class of its own resolves with the subscription base. The
  generated schema class names the three.

### Changed

- The classes of `Query` fields are looked up in `Resolvers` (`app/graphql/resolvers`), graphql-ruby's
  convention, instead of `Queries`: `Query.latestPosts` resolves to `Resolvers::LatestPosts`, and
  `lighthouse:query` writes there. To keep `app/graphql/queries`, set
  `config.namespaces = { queries: ['Queries'] }`.
- `lighthouse:subscription` no longer takes `--lighthouse`. The class inherits from
  `Subscriptions::BaseSubscription`, which includes the concern, and gets its hooks; under a base
  without the concern, it gets graphql-ruby's `authorized?` and `update`.

- Paginated fields (`@paginate`, and relationship directives given `type:`) cost
  `1 + child complexity × first` in the complexity score. A page of 1,000 items now scores
  1,000 times one item's cost; before, a paginator scored the same whatever `first` was.
  A schema that already sets `max_complexity` may need a higher limit.

## [0.3.0] - 2026-10-17

### Added

- `Lighthouse::GraphQL::Controller`, a Rails controller concern: `include` it, name the schema
  with `lighthouse_schema AppSchema`, and its `execute` action runs the operation through
  persisted queries, batches a JSON array body, reads the variables, sets the Cache-Control
  header and renders the result. Its private hooks (`graphql_context`, `graphql_variables`,
  `graphql_schema`) adjust it, and `lighthouse_request { }` gives an action of your own the
  request events. The generated `GraphqlController` and the example app now use it.
- Events, as PHP Lighthouse dispatches them (`docs/events.md`): `Lighthouse::Events.listen`
  for `StartRequest`, `StartOperationOrOperations`, `BuildSchemaString` (its listeners return SDL to add),
  `RegisterDirectiveNamespaces` (its listeners return namespaces of directive classes to register), `ManipulateAST`,
  `StartExecution`, `BuildExtensionsResponse` (its listeners return an `ExtensionsResponse` for the result's
  `extensions`), `ManipulateResult`, `EndExecution`, `EndOperationOrOperations`, `EndRequest`
  and `ValidateSchema`. Each one is also instrumented through `ActiveSupport::Notifications`
  as `<event>.lighthouse`.
- `@event(dispatch:)` dispatches an event class, constructed with the field's resolved value,
  once the field resolves. Event classes are looked up in `Config.namespaces[:events]` (`Events`).
- `PersistedQueries.multiplex` runs a batch of operations.
- `bin/rails lighthouse:validate_schema` dispatches `ValidateSchema` and builds every type.
- `@feature(name:, when:)` shows a field or object type only while a feature flag is in that
  state, checked per query through graphql-ruby's visibility. It uses Flipper by default;
  `Config.feature_checker` and `Config.feature_actor` change that.
- `@convertEmptyStringsToNull` on an argument, input field or field, or on every field with
  `Config.convert_empty_strings_to_null`, turns incoming `""` into `null`.
- Soft deletes: `@softDeletes` adds a `trashed: Trashed @trashed` argument (`ONLY`, `WITH`,
  `WITHOUT`), and `@restore` and `@forceDelete` restore or permanently delete the soft-deleted models
  their filters select. They work with paranoia, discard or a plain `deleted_at` column,
  detected per model, or with an adapter set in `Config.soft_deletes`.
- `@withoutGlobalScopes(names:)` lifts a model's default scope conditions when the client passes
  `true`. Each name is a `without_<name>` scope or a column.
- Subscriptions (`docs/subscriptions.md`), on graphql-ruby's subscriptions: `Subscription`
  fields resolve to plain `GraphQL::Schema::Subscription` classes in `Subscriptions::` by convention,
  or to the class `@subscription(class:)` names, or work with no class at all.
  `@broadcast(subscription:, shouldQueue:)` triggers a subscription once a mutation succeeds,
  inline or in an ActiveJob (`Config.queue_broadcasts`, `Config.broadcast_queue`), with the class's
  `self.trigger_arguments(root, context)` and `trigger_scope`; a plain class with required arguments
  and no `trigger_arguments` (which could never reach a subscriber) is reported as a
  `Lighthouse::DefinitionError`. The optional concern `Lighthouse::GraphQL::Subscription` adds PHP
  Lighthouse's `authorize?`, `filter?` and `resolve_payload` hooks. `rails generate lighthouse:subscription`
  writes a `GraphQL::Schema::Subscription` (`--lighthouse` to include the concern). The example app
  has real ActionCable subscriptions (`GraphqlChannel`) with channel and end-to-end delivery specs.
- The initializer `rails generate lighthouse:install` writes lists the new settings, and
  `docs/custom-directives.md` shows registering a namespace of directives through
  `RegisterDirectiveNamespaces`.

### Fixed

- Schemas using `@cacheControl` (or `@feature`) build on graphql 2.5 again. Their arguments
  with a default are now nullable (`maxAge: Int = 0`, not `Int! = 0`), because graphql 2.5 does not
  fill in a directive argument's default and so refused every usage that left one out. CI now
  also runs the suite on graphql 2.5.

## [0.2.1] - 2026-10-17

### Added

- RBS signatures in `sig/`, shipped with the gem, for the parts an app implements or calls:
  `Lighthouse::_Builder` (what a `@builder` class answers) and `_Validator`, every
  `Lighthouse::Config` setting with the callables it takes (`_ErrorHandler`, `_UserReader`,
  `_Authorizer`), the directive extension points (`DirectiveRegistry`, the contracts,
  `BaseDirectiveResolver`, `Directives::Arguments::Base`), the entrypoints (`get_schema`,
  `SchemaFactory`, `PersistedQueries`, `CacheControl`, `SchemaCache`, `IdeHelper`) and the
  errors. `rbs collection` (and so Steep) loads them from the installed gem, as it does for any
  gem that ships `sig/`; nothing changes at runtime.
  CI validates them and runs the suite with every Lighthouse method checked against its
  signature, so they cannot drift from the code.
- A documentation site, built from `docs/` with VuePress as PHP Lighthouse builds its own,
  and published to GitHub Pages on every push to `main`:
  <https://vaz-innovation.github.io/lighthouse-graphql/>.
- `docs/motivation.md`: where Lighthouse comes from, why the schema comes first, and why
  directives work so well on Active Record — and when something else fits better.

## [0.2.0] - 2026-10-17

### Added

- `rails generate lighthouse:install` sets a Rails app up: the initializer (every option,
  commented out at its default), a starter schema, the schema class with
  `GraphQL::Dataloader`, a `GraphqlController` and its route, and a `graphql.config.yml`
  for IDEs. `--schema`, `--sdl-folder`, `--skip-controller` and `--skip-ide` adjust it;
  rerunning it adds the route and `.gitignore` entries only once. It coexists with
  graphql-ruby's `graphql:install`: an existing controller or schema class is kept unless
  `--force` is given, and the route is written exactly as graphql-ruby writes it, so it is
  never added twice in either order.
- `bin/rails lighthouse:ide_helper` writes `schema-directives.graphql` (every registered
  directive the SDL does not declare) and `programmatic-types.graphql` (the types the
  manipulation phase generates) so IDEs can validate and autocomplete a Lighthouse
  schema, as PHP Lighthouse's `lighthouse:ide-helper` does.
- `DirectiveRegistry#register_definition` contributes the SDL definition of a directive
  that has no class of its own; `register_type_definition` / a class's `type_definitions`
  contribute the types such definitions refer to, injected alongside them.
- **Queries, mutations and builders as separate kinds**, each with its own namespace
  (`Config.namespaces`) and contract. A `Query` or `Mutation` field without a resolving
  directive resolves by convention to `Queries::<FieldName>` (a `GraphQL::Schema::Resolver`)
  or `Mutations::<FieldName>` (a `GraphQL::Schema::Mutation`, `RelayClassicMutation`
  included) — graphql-ruby's contract: `resolve(**args)`, `object`, `context`, `ready?`,
  `authorized?`. `@field(resolver:)` on those roots looks in the same namespaces. `@builder`
  classes live in `Builders::`. Generators: `lighthouse:query`, `lighthouse:mutation`,
  `lighthouse:builder`, `lighthouse:validator`.
- `@create`, `@createMany`, `@update`, `@updateMany`: save the returned model through
  ActiveRecord, in a transaction (`Config.transactional_mutations`), reporting model
  validation errors by argument path (`extensions.validation`, as in PHP Lighthouse).
  `@spread` flattens an input into the arguments, `@inject(context:, name:)` sets
  server-side values, `@rename` now also applies to arguments.
- `@validator` (field or input type) runs a contract before the field resolves:
  a `Dry::Validation::Contract` (optional dependency) or any `call(values)` returning
  errors. Input-type validators apply wherever the type is used, nested and in lists.
- The `@can*` family, Pundit by default: `@canFind`, `@canModel`, `@canQuery`,
  `@canResolved`, `@canRoot`, with `injectArgs`, `args`, `action`
  (`EXCEPTION_PASS` / `EXCEPTION_NOT_AUTHORIZED` / `RETURN_VALUE`) and `returnValue`. The
  authorizer receives those arguments as a fourth parameter, only when there are any.
- `@cache(maxAge:, private:)`, `@cacheKey` and `@clearCache(type:, idSource:, field:)` over
  `Config.cache_store` (`Rails.cache`), invalidating through versioned keys so it works on
  any store, including ones without `delete_matched`.
- **Nested mutations**, PHP Lighthouse's API over ActiveRecord: an input field named after
  an association carries `connect` / `create` / `update` / `upsert` / `disconnect` /
  `delete` (belongs_to, polymorphic belongs_to, has_one, has_many) and `sync` /
  `syncWithoutDetaching` (has_many :through, has_and_belongs_to_many — with pivot columns on a
  `:through` join model), to any depth. Each record is saved once; errors are keyed by the full
  input path. `@create` / `@update` / `@upsert` / `@delete(relation:)` on an argument run one
  operation on an association.
- `@upsert` / `@upsertMany` (by primary key or `identifyingColumns`) and `@delete` (by the
  field's filter arguments; refuses to delete without one), and the `@whereKey` filter.
- `@paginate(type: PAGINATOR | SIMPLE | CONNECTION, scopes:, defaultCount:, maxCount:)` and
  `type:` on `@hasMany` / `@belongsToMany` / `@morphMany` / `@morphToMany`, generating PHP
  Lighthouse's types and arguments (`first`, `page`, `after`; `PaginatorInfo`,
  `SimplePaginatorInfo`, `PageInfo` with `total` / `count` / `currentPage` / `lastPage`). The total
  is only counted when selected. `Config.pagination_default_count` / `pagination_max_count`.
- `@morphTo`, `@morphOne`, `@morphMany`, `@morphToMany` (ActiveRecord polymorphic
  associations), and `scopes:` on every relationship directive.
- The integration suites of PHP Lighthouse for nested mutations (belongsTo, hasOne, hasMany,
  belongsToMany, morphTo, morphOne, morphMany, morphToMany), the model mutation directives,
  `@all` and `@paginate`, ported to RSpec against the same models (spec/integration).
- **Opt-in options for large schemas and high traffic**, all off by default (docs/performance.md):
  - `config.schema_cache` caches the built schema document in `tmp/cache/lighthouse`, Bootsnap
    style: content-addressed (SDL, versions, registered directives, manipulator source, config),
    so it invalidates itself; atomic writes; `bin/rails lighthouse:cache` / `lighthouse:clear_cache`.
    About 1.8x faster schema builds on large schemas.
  - `config.watch_sdl` adds the SDL folder to Rails' watched dirs, so editing a `.graphql` file
    reloads the schema in development (it previously needed a server restart).
  - `config.persisted_queries`: Apollo-compatible Automatic Persisted Queries
    (`PersistedQueries.execute`, used by the generated controller), with a TTL, a store, a
    manifest of trusted operations (Apollo's format or `{ sha256 => query }`) served from memory,
    `persisted_queries_only` as an allowlist, and `bin/rails lighthouse:persisted_queries:verify`
    to check the manifest against the schema in CI.
- `@cacheControl(maxAge:, scope:, inheritMaxAge:)` computes the response's `Cache-Control`
  header from the selected fields (PHP Lighthouse's / Apollo's rules);
  `Lighthouse::GraphQL::CacheControl.apply(response, result)` sets it, and the generated
  controller calls it.
- `example/`: a Rails 8.1 blog API built with Lighthouse, which is both an example to
  read and the end-to-end suite. Its specs go through the real `/graphql` endpoint:
  queries, pagination, relationships without N+1, `@guard` and the `@can*` family with
  Pundit, mutations (nested ones included), validation, `@cache`/`@cacheControl`,
  persisted queries over `GET`, and the rake tasks. CI runs it.
- RuboCop (with rubocop-rails, -rspec, -performance and -factory_bot) lints the gem and
  the example app; CI runs it, and `rake` runs it after the suite.
- **Paginated relations no longer query once per parent.** `@hasMany`,
  `@belongsToMany`, `@morphMany` and `@morphToMany` with `type:`, and `@paginate` on a
  nested field, load every parent's page in one query (a `ROW_NUMBER()` window
  partitioned by parent) and every total in one `GROUP BY`, only when a total is
  selected. Databases without window functions keep loading one parent at a time. See
  docs/relationships.md.

### Fixed

- `@whereConditions`' `AND`, `OR` and `HAS` were ignored when they came from a query.
  graphql-ruby hands input objects over with Ruby-style keys (`:and`, `:or`, `:has`), and
  only the upper-case keys were read, so a nested condition matched every record.
- `scopes:` was declared but ignored by `@count` and `@first`; `@all` now accepts it too.
- The default resolver discarded the result of a generated three-argument resolver
  (`resolve_field_<name>(obj, args, ctx)`) and fell through to reading the attribute.
- Used standalone (without Rails), the gem missed ActiveSupport's `Enumerable` and
  `String#exclude?` extensions it relies on (`index_by`, `pluck`, `exclude?`).

- Every built-in directive now contributes its SDL definition. `@all`, `@find`,
  `@paginate`, `@hasMany`, `@belongsTo`, `@belongsToMany`, `@aggregate`, `@field`,
  `@auth`, `@builder`, `@whereConditions` and `@whereHasConditions` had none, so a schema
  that used one without declaring it failed to build — contrary to the docs.
- `@find` without `model:` found nothing: it inferred the model from the return type's
  Ruby class name, which is `nil` for SDL-built types, instead of its GraphQL name.
- `@find` returned `null` for existing records when batched through the Dataloader: `ID`
  arguments arrive as strings and were looked up against integer primary keys.
- Wrapping directives (`@guard`, ...) on a field without a resolving directive called
  graphql-ruby's internal resolver with the wrong arity instead of the default reader.
- The gem now requires `graphql` itself instead of relying on the app to load it first.
- `@all` on a list field returned `nodes: null`: the field was rewritten to a connection the
  resolver never built. `@all` now returns the list, as in PHP Lighthouse; it also resolved
  `model:` ignoring `resolver_namespaces` and stripping the namespace (`Admin::User` → `User`).
- `@paginate` ignored the field's argument filters (`@eq`, `@like`, ...), took no `first` /
  `page` arguments as a paginator, and returned `nodes: null` as a connection.
- `@find` ignored every argument but `id`; it now applies the argument filters and errors on
  more than one match.
- The relationship directives' Dataloader source loaded each parent's association separately
  (N+1); it now batches with ActiveRecord's preloader.
- The relationship directives and `@find` raised "Dataloader is not running" on schemas without
  `GraphQL::Dataloader`; they now load directly there.
- Generated pagination wrappers made every paginated field `no-cache` under `@cacheControl`;
  they now inherit the parent's maxAge, as in PHP Lighthouse.
- An explicit `null` directive argument (`@paginate(maxCount: null)`) failed to build the
  schema: graphql-ruby passes it on as a NullValue node. Lighthouse maps it to nil.

### Removed

- **`@can`** — replaced by the `@can*` family. `@can(ability:)` becomes `@canResolved`,
  `root: true` becomes `@canRoot`, `find:` / `model:` become `@canFind`; see the migration
  table in docs/authorization.md. Schemas still using `@can` fail to build.

### Changed

- **`@hasMany` and `@belongsToMany` return plain lists**, as in PHP Lighthouse, instead of
  connections. Pass `type: CONNECTION` (or `PAGINATOR` / `SIMPLE`) to paginate; clients that
  selected `edges` / `nodes` on them need the `type:`.
- Paginated fields follow PHP Lighthouse: a paginator takes `first: Int!` (defaulted by
  `defaultCount`) and `page`, a connection `first: Int!` and `after`, and returns non-null.
- `@paginate`'s `type:` is the `PaginateType` enum (`PAGINATOR`, `SIMPLE`, `CONNECTION`); the
  string form still works at runtime.
- `@builder` classes are looked up in `Config.namespaces[:builders]` (`Builders::`) instead of
  `resolver_namespaces`. Fully-qualified names work as before.
- `@field(resolver:)` on `Query` / `Mutation` looks in the queries / mutations namespaces;
  elsewhere still in `resolver_namespaces`.
- `@aggregate`'s `function:` is declared as `String`. Enum
  literals (`function: SUM`) still work at runtime, but IDEs expect strings
  (`function: "SUM"`).

## [0.1.1] - 2026-09-23

Release tooling only: the library is unchanged from `0.1.0`. The packaged gem differs because
`spec.files` ships the README and this file.

### Changed

- The release workflow asks RubyGems whether the version is already published and skips the
  push if it is. RubyGems refuses to overwrite a version, so without that check a release that
  failed *after* the push — a flaky GitHub API call, a changelog section that did not parse —
  could never be re-run to completion.
- The README carries gem, CI and license badges.

## [0.1.0] - 2026-09-23

First release on RubyGems. Everything below is what the gem ships with; the library
had been running inside a private monorepo as a path gem before being extracted.

### Added

- Registry-driven directive dispatch (`Lighthouse::DirectiveRegistry`): adding a
  directive is "write one class and register it" — no edits to the generator.
- Directive contracts (`Lighthouse::Contracts::*`) mirroring PHP Lighthouse's
  interfaces: `FieldResolver`, `FieldMiddleware`, `FieldManipulator`,
  `ArgManipulator`, `ArgBuilder`.
- Read directives: `@all`, `@find`, `@first`, `@paginate`, `@count`,
  `@aggregate`, `@hasMany`, `@hasOne`, `@belongsTo`, `@belongsToMany`,
  `@field`, `@rename`, `@auth`, `@builder`, `@orderBy`, and the argument
  filters `@eq`, `@neq`, `@in`, `@notIn`, `@like`, `@where`, plus
  `@whereConditions` / `@whereHasConditions`.
- `@method(name:)` — resolve a field by calling a method on the parent object
  (PHP-parity); removes one-line "call a method" resolvers.
- Authorization directives `@guard` (require authentication) and `@can`
  (policy-based authorization, Pundit by default) with configurable
  `authenticated_user` / `policy_user` / `authorizer` seams — declare auth in
  the schema instead of in resolvers.
- `BuilderApplier` / argument builders now re-raise `GraphQL::ExecutionError`
  instead of swallowing it, so authorization/scoping guards in a builder cannot
  be silently bypassed.
- Central naming module (`Lighthouse::Support::Naming`): one rule mapping GraphQL
  camelCase to Rails snake_case attributes/columns, with `@rename` as the
  explicit override.
- Programmatic directive SDL: registered directives contribute their own
  `directive @name(...) on ...` definitions, so apps need not hand-declare them.
- Apollo Federation entity binding: `@key`/`@extends`/`@shareable`/
  `@inaccessible` and `resolve_reference`, with a default model-lookup fallback
  for direct-model entities and a `ReferenceResolver` registry for custom ones.
- Config-driven extension seams: `Lighthouse.configure`, `resolver_namespaces`,
  `on_error`, and `DirectiveRegistry.register` for app-defined directives.

[Unreleased]: https://github.com/Vaz-Innovation/lighthouse-graphql/compare/v0.4.0...HEAD
[0.4.0]: https://github.com/Vaz-Innovation/lighthouse-graphql/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/Vaz-Innovation/lighthouse-graphql/compare/v0.2.1...v0.3.0
[0.2.1]: https://github.com/Vaz-Innovation/lighthouse-graphql/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/Vaz-Innovation/lighthouse-graphql/compare/v0.1.1...v0.2.0
[0.1.1]: https://github.com/Vaz-Innovation/lighthouse-graphql/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/Vaz-Innovation/lighthouse-graphql/releases/tag/v0.1.0
