# Changelog

All notable changes to `lighthouse-graphql` are documented here. The format is
based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and this
project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **`@search`**, PHP Lighthouse's directive, with its definition: on a `String` argument, a string
  from the client (`""` too) runs the field's query through a full-text engine instead of the
  database; `null` or nothing falls back to it. `within:` names the index (Searchkick) or the
  `pg_search_scope`. Ruby has no Laravel Scout, so two gems back it behind one adapter seam
  (`Lighthouse::Search`), neither a dependency of Lighthouse: **Searchkick** (Elasticsearch /
  OpenSearch) answers with the records it found, in relevance order, for `@all`, `@paginate`
  (all three types; the total comes with the page, one request, and `first: 0` can count, which Scout
  cannot) and a resolver of your own. The total is exact past the 10,000 matches the engines stop
  counting at (`track_total_hits`), a search reads within the index's result window
  (`max_result_window`, read from the model, whatever its settings' keys; left to the engine for
  another index `within:` names): a page past it is an error the client reads, and `@all` without
  `first` reads 10,000 records at most, even with `deep_paging`. **pg_search** (2.3 and 2.4) is a
  scope on the relation, so `scopes:`, `@builder`, `@whereAuth`, the argument filters, `@orderBy`,
  nested fields, batched nested `@paginate` and mass mutations all apply on top of it, the rank
  first (before the model's default order too), then the orders that break its ties, then the
  primary key, so equal matches keep one order on every field. A mass mutation (`@delete`, ...) counts a `@search` argument as a filter only when
  the search runs, as PHP Lighthouse. The engine is detected per model, and for a model with both
  gems a `within:` naming a pg_search scope picks pg_search; `Config.search` replaces the detection. `@eq`,
  `@trashed` and `@builder` on an argument narrow a Searchkick search through the new
  `Contracts::SearchBuilder` and `Lighthouse::Search::Query`, as Scout's `ScoutBuilderDirective`.
  `@trashed` filters on the soft-delete column the index holds, the one `Config.soft_deletes` filters
  the database on (with paranoia's sentinel value; adapters may tell it with `column(model)` and
  `kept_value(model)`; it is the one place to name it), and `ONLY` / `WITH` load the trashed records
  past the default scope that hides them (paranoia's, discard's).
  A model's `search_results` scope, when it has one, is what a search of it may return: Searchkick
  loads the records it finds through it (`scope_results:`), so a record a stale index still holds
  is not returned. `@canQuery` on a searched field checks every record the search finds, as PHP
  Lighthouse does (with Searchkick, 10,000 at most: a search that finds more a page could reach is
  an error), and `resolve_info.enhance_builder` answers a `Lighthouse::Search::Result` for a
  Searchkick search, as PHP Lighthouse answers Scout's builder, so a field your own class resolves
  can search through it; the relation it gets must select what the model's own does (`Post.all`,
  or `Post`), any other is refused. Each resolver class declares whether it applies a search and
  takes an engine's records (`applies_search?`, `takes_search_results?`).
  See [Full-text search](docs/filtering-and-ordering.md#full-text-search).

### Changed

- **`@search` is stricter than PHP Lighthouse where it drops a constraint silently.** With an engine
  outside the database (Searchkick) PHP Lighthouse ignores the field's `scopes:`, `@builder`,
  `@whereAuth` and `@orderBy(column:)` when it searches, so a search that skipped `@whereAuth`
  returns records the user must not see. Here that field is a schema error at build, as are `@search`
  on a model that is not searchable, a `within:` that is not a string, a `@search` nothing applies
  (graphql-ruby's default reader, `@create`, ...), which PHP Lighthouse ignores, and, with
  Searchkick, any field but `@all`, `@paginate` of the model's whole table and a resolver of your
  own, an `@canQuery` with `scopes:`, and a value graphql-ruby fills in without the client (an
  argument's default, the fields of a default object) whose directive the engine cannot apply (PHP
  Lighthouse fails every search of such a field). A relational engine (pg_search) applies them all.
  `enhance_builder` refuses, with Searchkick, a relation that selects other records than the
  model's own (a narrowed one, `unscoped`, `with_deleted`, ...), whose conditions PHP Lighthouse
  drops.

## [0.8.2] - 2026-10-30

### Fixed

- **`@globalId(decode: ID)` checks the type of the id** (#6). It kept the id and dropped the
  type, so another type's global id found the record with the same number:
  `user(id: <a Post's id>)` answered user 1, and `@delete` / `@forceDelete` could act on a
  record the client did not name. An argument that filters the field's model by its key
  (`@whereKey`, `@eq`/`@in` on the primary key, or `id`), on the field or in an input it
  takes, now fails with `"…" is not a valid global id for User.` given another type's id;
  a subclass (STI) or a type whose `@model` is the field's model passes. The new
  `@globalId(type: "User")` names the type anywhere else. PHP Lighthouse does not check.

## [0.8.1] - 2026-10-30

### Changed

- **The RBS signatures are typed.** What Lighthouse takes from graphql-ruby, Active Record
  and Rails, which ship no RBS, was `untyped`; it is now declared as interfaces of the methods
  Lighthouse uses (`_Schema`, `_Result`, `_Context`, `_Query`, `_Relation`, `_DirectiveNode`,
  `_Request`, ...), so Steep checks code that calls Lighthouse and `rake rbs:test` checks the
  suite's real values against them. Results are `Hash[String, json]`, directive arguments
  `literal`, `Events.listen` has an overload per event class, with the block's event and
  answer typed. `untyped` is left for the app's own values (a user, a client's argument
  value): 169 became 76. Typing found `BuilderApplier.apply` called without a context, which
  the signature now allows.

### Removed

- `Config.directive_map`, a setting nothing read.

### Added

- **`Unauthenticated.` and `This action is unauthorized.` carry an `extensions.code`** (#5):
  `UNAUTHENTICATED` from `@guard` and `@auth` (the new `Lighthouse::AuthenticationError`), and
  `FORBIDDEN` from the `@can*` directives (`Lighthouse::AuthorizationError`), as Apollo names
  them, so a client can react without matching the message. PHP Lighthouse's have no code.
- **`EndExecution` says which operation ended** (#4): `operation_name`, `context`, and the
  `GraphQL::Query` as `graphql_query`, which `StartExecution` carries too. In a batch every
  `StartExecution` comes before any `EndExecution`, so a listener could not tell the results
  apart.

## [0.8.0] - 2026-10-29

### Added

- **`config.schema_log` reports the schema on boot and on every reload in development**: a
  pretty-printed `✓` with the build time, the number of types and root fields, what the reload
  added and removed (`+ User.nickname   − Post.legacyTitle`) and the files written, or a `✗`
  with the error the next request would raise, plus the persisted operations the schema no
  longer accepts. On by default in a development server (not rake tasks or the console),
  through the Rails logger, and on the terminal from boot.
- **`@attachment` answers the URL of an ActiveStorage attachment**, or the URLs of a
  `has_many_attached`: the read side of `@upload`. Every parent's attachments and blobs load
  at once (two queries for any number of parents), the name defaults to the field's without
  `Url`/`Urls` (`avatarUrl` reads `avatar`), and `url:` picks Rails' `REDIRECT` (default),
  `PROXY`, or the service's `DIRECT` URL signed for `expiresIn`; `variant:` names a variant.
- **`@canModel` on an argument or input field: who may use it.** It checks its ability against
  the model only when the client gives that argument a value, at any depth (in each input of
  a list too), with the field's `@can*` directives and their `action:`.
  `@softDeletes(ability: "view_trashed")` puts it on the `trashed` argument it adds, so
  listing trashed records can be for admins only.
- **`lighthouse_execute` runs an operation from any controller action (#3)**, with the context the
  GraphQL endpoint gives it (`graphql_context`, and the IP and controller `@throttle` counts
  with), to render a page with its data loaded. It comes from the new
  `Lighthouse::GraphQL::Operations` concern, which any controller can include (with
  `lighthouse_schema`), and which `Lighthouse::GraphQL::Controller` includes. It returns the
  result, or `nil` when a `@throttle` answered the request with a 429.
- `config.persisted_queries_manifest` takes a Hash of operations, or a callable answering a
  Hash or a path (called per persisted query), besides a JSON file: a frontend build can keep
  its trusted documents where it writes them. A Hash is checked once, until its content changes.
- **`config.schema_output` keeps the client schema in a file, in development**, for a codegen
  to read, as NestJS's `autoSchemaFile`: rewritten on boot and on every reload, only when it
  changed (atomically, so a watcher never reads half of it). A path (`.json` for the
  introspection result), or `{ path:, schema: }`. `bin/rails lighthouse:schema_output:verify`
  fails in CI when the committed file is out of date.
- `lighthouse:print_schema` takes PHP Lighthouse's options: `FORMAT=json` (the introspection
  result), `FORMAT=federation` (a subgraph's SDL), and `WRITE=1` / `WRITE=path` to write a
  file (schema_output's, else `lighthouse-schema.graphql`). graphql-ruby already prints in
  alphabetical order, so there is no `--sort`. With no `SCHEMA=`, it and the other tasks
  (`validate_schema`, `persisted_queries:verify`) take `<App>Schema`, the name graphql-ruby's
  install gives, before trying `AppSchema`.

### Changed

- **Clients no longer see Lighthouse's directives.** Introspection listed every directive
  Lighthouse injects to build the schema (`@all`, `@canFind`, `@inject`, `@hash`, ... 96 in
  the example app), with the types only they use (`CanAction`, `FeatureState`), and
  `to_definition` / `lighthouse:print_schema` printed their definitions and every use
  (`author: User! @belongsTo`). As in PHP Lighthouse, whose schema holds only the standard
  directives and those the SDL declares, they are now taken out of the built schema: a client
  sees `@skip`, `@include`, `@deprecated`, `@oneOf`, `@specifiedBy` and the SDL's own, and an
  operation using `@all` is invalid. Lighthouse reads its directives from the SDL, so nothing
  else changes.

### Fixed

- **`@upload` purges what it stored when the field fails.** It stores a file before the
  field resolves, and a model's validations run after: a `@create` the model refused left
  its blobs in the bucket (#1). The blobs `@upload` stored for a field that raises, returns
  an error or adds one to the context are now purged before the response (one the storage
  service fails to delete is left to `purge_later`). The uploads guide now
  recommends passing the file to the attachment attribute, which ActiveStorage uploads
  only after commit.
- **Paginated queries end their order with the primary key.** Pages are cut by position, so
  rows the field's order tied (`@orderBy(column: "created_at")`) could come back in another
  order on the next page's query, and show on two pages or none; the same in the per-parent
  row numbers of a batched relation. `@paginate` (every `type:`) and the paginated relation
  directives now append the primary key unless the order names it already. PHP Lighthouse
  leaves the order as it is.
- **`@globalId(decode:)` no longer loads the record to read its id (#2).** On a schema with
  graphql-ruby's `object_from_id` (Rails' GlobalID, as its install writes it), decoding went
  through `object_from_id`: a SELECT before `@find`'s own, under the model's default scope,
  so a soft-deleted record's id did not decode for `@restore` / `@forceDelete` with an
  `object_from_id` that kept the scope. A Rails GlobalID now decodes without the database,
  as PHP Lighthouse's `decodeID` does; only an id of another format goes through
  `object_from_id`.
- A directive the SDL uses that is neither built in, Lighthouse's nor declared fails the build
  with ``No directive found for `@can` on Query.a.``, as PHP Lighthouse names it. On a root type
  it failed with a `NoMethodError` from inside graphql-ruby.

- **An optional `Upload` takes an explicit `null`.** The scalar refused it ("Could not get
  uploaded file ... Instead got: nil"), so a client had to leave the argument out. `null`
  now reaches the resolver as `nil`, and `@upload` stores nothing for it.
- **`@canFind` fails when nothing is at its `find:` path, instead of passing unchecked.** A
  misspelt path (`find: "inputt.id"`), or an optional argument the client left out, found
  no ids, so no model was checked and the field resolved. It now fails with `Got no key to
  find a model at the expected input path: …`, as PHP Lighthouse does (through `action:`,
  like the other failures). A `*` over an empty list still checks no model.

## [0.7.3] - 2026-10-29

### Changed

- **Filters on input fields apply without `@nest`, as in PHP Lighthouse.** The filter
  directives (`@eq`, `@where`, `@like`, ...) on an input object's fields apply whenever the
  client sends it: at any depth, for every input of a list (together), and through `@spread`,
  as PHP Lighthouse's `applyArgBuilderDirectives` goes through nested inputs. They used to
  apply only under an argument marked `@nest`, which is still accepted and changes nothing.
  `posts(filter: PostFilter): [Post!]! @all` filters by the `@eq` inside `PostFilter`.

### Fixed

- **A definition of a built-in directive in the SDL no longer disables it.** graphql-ruby
  replaced its `@oneOf`, `@skip`, `@include`, `@deprecated` and `@specifiedBy` with a plain
  directive of the same name when the SDL declared one (`directive @oneOf on INPUT_OBJECT`),
  so a `@oneOf` input accepted any number of fields while introspection still reported
  `isOneOf: true`, and `@skip` skipped nothing. Lighthouse now drops those definitions and
  keeps graphql-ruby's directives.
- A relation field (`@hasMany`, ...) filtered only through an input object's fields took the
  batched load and ignored the filters, and `@delete`, `@forceDelete` and `@restore` refused
  such an argument as no filter ("Would modify all models"). Both now see nested filters.

### Added

- `@oneOf` input objects are documented and specced
  ([Filtering & Ordering](docs/filtering-and-ordering.md#one-filter-of-several-oneof)):
  `user(by: UserBy!): User @find` finds by whichever one field the client gives, and
  graphql-ruby rejects a query giving none or more than one.

## [0.7.2] - 2026-10-29

### Added

- `bin/rails lighthouse:print_schema` prints the final schema, as PHP Lighthouse's
  `lighthouse:print-schema` does: to stdout, from the current configuration
  (`SCHEMA=AppSchema` names another schema). Redirect it to keep it:
  `bin/rails lighthouse:print_schema > generated.graphql`.

### Changed

- **`schema-directives.graphql` documents everything.** Every directive, argument, enum value
  and input field Lighthouse defines carries a description, so the IDE shows it on hover and in
  autocomplete. A spec fails when a new one is added without.
- `programmatic-types.graphql` always declares the `_` placeholder scalar (unless your SDL
  declares it), whether or not the SDL uses it yet, so the IDE never reports `Unknown type "_"`
  the moment you write `where: _ @whereConditions`.
- The `_` placeholder exists only for the IDE: a `scalar _` in your SDL is dropped once the
  schema builds, so the executable schema (and its introspection) has no `_` type.

### Fixed

- Builds on graphql-ruby 2.6.14, whose changed internals made the root types
  (`Types::QueryType`, ...) lose the app's code-first base.

## [0.7.1] - 2026-10-18

### Added

- **`lighthouse:install` on graphql-ruby's Relay** (`--relay`, its default) writes `node(id:)`
  and `nodes(ids:)` in the starter `graphql/schema.graphql`, with `interface Node` and a
  `User @node` whose ids are global (`id: ID! @globalId`, `user(id: ID! @globalId(decode: ID) @eq)`).
  Graphql-ruby's `field :node` / `field :nodes` move out of `Types::QueryType`, whose
  `#node` / `#nodes` methods resolve the SDL's fields. This happens only when the schema file
  does not exist yet. An install without Relay writes the starter schema as before.

## [0.7.0] - 2026-10-18

The schema is written by PHP Lighthouse's rules now: one entrypoint that imports
the other files, every type defined once, and `extend type` to add to it.
`@orderBy`, `@whereConditions` and `@whereHasConditions` generate and apply what
PHP Lighthouse's do. In development, the IDE helper files are rewritten
automatically.

**Upgrading from 0.6:**

1. Replace `config.sdl_folder = ...` with `config.schema_path = Rails.root.join('graphql/schema.graphql').to_s`
   (that is the default), and `get_schema(sdl_folder:)` with `get_schema(schema_path:)`.
2. Import every other file from `graphql/schema.graphql`. `#import **/*.graphql` imports
   every file below its folder, which matches what was loaded before.
3. Turn a second `type Query { ... }` (or `type Mutation`, or any type defined in two files)
   into `extend type Query { ... }`. A type defined twice now fails the build.
4. Write `orderBy:` arguments as `orderBy: _ @orderBy(columns: [...])`, and drop the
   `OrderByClause` inputs and the `SortOrder` enum you declared. `order` is required in a
   clause, and `{ field:, direction: }` clauses are no longer accepted.
5. `SQLOperator` has PHP Lighthouse's values. Replace `NIN` with `NOT_IN`, and
   `CONTAINS` / `STARTS_WITH` / `ENDS_WITH` with `LIKE` and a `%` pattern
   (`value: "%Rails%"`, `"Rails%"`, `"%Rails"`). `@where(operator:)` keeps its operators.
6. A `HAS` condition is on the related records' columns (`…HasCondition`, a `String`
   column), as in PHP Lighthouse, no longer on the parent's column enum.

### Added

- **`#import`.** The schema's entrypoint, `config.schema_path`, imports other files by a
  path relative to the importing file. Globs (`#import blog/*.graphql`) work too. An
  imported file can import more files, and each file is read once.
- **Type extensions merged as PHP Lighthouse merges them.** `extend type`, `input`,
  `interface`, `enum`, `union` and `scalar` add to their definition, and the
  directives on their fields work as on the type's own. `extend type Query` alone
  defines `Query`.
- **`@orderBy` generates its types.** `orderBy: _ @orderBy(columns: [...])` gets
  `[<Type><Field><Arg>OrderByClause!]`, a column enum (`@enum(value:)` per column)
  and `SortOrder`. `columnsEnum:` reuses an enum, and without columns the shared
  `OrderByClause` takes any column.
- **`@orderBy(relations:)`.** Clients order by `COUNT` of a relation, or by
  `AVG`/`MIN`/`MAX`/`SUM` of one of its columns
  (`{ posts: { aggregate: COUNT }, order: DESC }`). Records without related ones
  are ordered too, and this works on batched relationship pages.
- **`@orderBy(column:, direction:)` on a field.** It always orders the result, after
  the client's clauses.
- **`@whereConditions` and `@whereHasConditions`, as in PHP Lighthouse.** They have
  PHP Lighthouse's `SQLOperator` (`LIKE`, `NOT_LIKE`, `NOT_IN`, `BETWEEN`,
  `NOT_BETWEEN`, ...), and `HAS` with `operator:` / `amount:`
  (`{ relation: "posts", operator: LT, amount: 1 }`: the records with none). The
  `…Relation` / `…HasCondition` inputs filter on the related table, and
  `handler:` names a class that applies the conditions instead.
- **JSON columns.** `@whereConditions`, `@whereHasConditions` and `@orderBy` take a path into a
  JSON column, `meta->author->name` or `meta->tags->0`, on PostgreSQL, MySQL and SQLite.
  Numbers compare and sort as numbers, booleans compare as booleans, and `IS_NULL` holds
  for a JSON `null` too.
- **`config.ide_helper`.** `schema-directives.graphql` and
  `programmatic-types.graphql` are rewritten on boot and on every reload. By
  default this happens in development when the app has a `graphql.config.yml`.
- `Contracts::FieldBuilder`, and `Contracts::ArgManipulator` as `ASTBuilder` calls
  it, for custom directives.
- The guide [docs/schema-organisation.md](docs/schema-organisation.md).

### Changed

- **Breaking:** The schema is read from `config.schema_path` and its imports, not from every
  file in `config.sdl_folder`, which is removed. `lighthouse:install` takes `--schema-path`
  instead of `--sdl-folder`.
- **Breaking:** A type defined twice fails the build: "Duplicate definition X found when parsing
  the schema", pointing at `extend`. PHP Lighthouse keeps the last definition.
- **Breaking:** An argument typed `_` that no directive replaces fails the build. It used to
  become a scalar.
- **Breaking:** `@orderBy` clauses need `order`, take only `{ column:, order: }`, and a
  column outside an enum must be an identifier.
- **Breaking:** `SQLOperator`'s values are PHP Lighthouse's (see above).
- **Breaking:** `@builder` and `@whereAuth` on a field apply after the argument directives,
  as PHP Lighthouse's field builder directives do. An `order` a builder adds now breaks the
  ties of the client's `orderBy` instead of preceding it. They also apply on relationship
  fields (`@hasMany`, ...), where they used to be ignored, and on `@aggregate`, which now
  gets the argument directives too.

### Fixed

- A schema that stops building while you edit it keeps its `programmatic-types.graphql`.
  If there is none yet, the file declares the `_` placeholder alone, so the IDE never
  reports `Unknown type "_"`. When an import is missing, the IDE helper reads every
  `.graphql` file in the folder, as the IDE does.
- `programmatic-types.graphql` no longer repeats the types `schema-directives.graphql`
  defines (`Mixed`, `CanAction`, `PaginateType`, ...). graphql-js, which the VS Code
  and JetBrains GraphQL plugins use, rejected the schema.
- `@whereConditions` applied only to an argument named `where`. It and `@whereHasConditions`
  are argument directives like the others now: any name, in SDL order.
- An error in a `@whereConditions` value (an unknown relation or operator) is the client's
  error. It used to be swallowed and leave the query unfiltered.

## [0.6.0] - 2026-10-18

Lighthouse now uses what the Rails app and graphql-ruby already have instead of settings and
files of its own: the app's cache, its controllers' rate limiting, its ActiveStorage, and
everything graphql-ruby's `graphql:install` writes, which `lighthouse:install` now builds on.
Several defaults change.

**Upgrading from 0.5:**

1. Remove `config.cache_store =` and `config.upload_store =` from
   `config/initializers/lighthouse.rb`. Configure the app's `config.cache_store` instead, and
   `config.action_controller.cache_store` if rate limits should be counted somewhere else.
2. `@throttle` counts per IP now. Add `by: "current_user.id"` where a field counted per user.
3. Past a `@throttle` limit the request is answered with a 429, as Rails' `rate_limit` answers it.
   To fail only the field, as before, give `with:` a controller method that raises a
   `GraphQL::ExecutionError`.
4. `@upload` checks `public:` against the ActiveStorage service. On a public service, add
   `public: true`. Where `public: true` meets a private service, name a public one with `disk:`.
5. `rails g lighthouse:query` and `lighthouse:mutation` are gone. Resolve a root field with a
   method of `Types::QueryType` / `MutationType`, with `rails g graphql:mutation`, or with a
   `Resolvers::` / `Mutations::` class written by hand, which convention still finds. An app
   installed with 0.5 keeps working as it is: `AppSchema = get_schema(...)` is still supported.

### Added

- `@throttle(by:)`: who the client is, as `rate_limit`'s `by:`. It is a path in the context, read
  as `@inject` reads one (`by: "current_user.id"`).
- `@throttle(with:)`: a controller method to call past the limit, as `rate_limit`'s `with:`. One
  that renders or redirects ends the request with its response, as a `before_action` that renders
  does. One that returns lets the call through, and one that raises a `GraphQL::ExecutionError`
  fails only the field.
- `@throttle` refusals are instrumented as `rate_limit.action_controller`, with `rate_limit`'s
  payload (`request`, `count`, `to`, `within`, `by`, `name`, `scope`, `cache_key`).
- `base_types` takes graphql-ruby's code-first root types and Node interface. The SDL's root type
  of a kind is built on `query_type:` / `mutation_type:` / `subscription_type:` (`Types::QueryType`),
  so the `field`s the class declares (graphql-ruby's Relay `node` and `nodes`, what
  `graphql:mutation` adds to `Types::MutationType`) are the schema's too, beside the SDL's, and
  resolve as in graphql-ruby. With no such root type in the SDL, the class is the root. `node:`
  (`Types::NodeType`) is the SDL's `Node` interface, which `@node` types implement, so
  graphql-ruby's Relay and `@node` share one `Node`.
- A root field with no resolving directive resolves with the method of its name on the root type
  class, when the class includes `Lighthouse::GraphQL::Type` (`Query.latestPosts` →
  `Types::QueryType#latest_posts`), before the conventional `Resolvers::` / `Mutations::` class.
- A schema that implements graphql-ruby's `id_from_object` / `object_from_id` has one kind of
  global id: `@globalId` encodes an object's own id with `id_from_object`, and decodes an
  argument with `object_from_id`.
- `lighthouse:install --subscriptions` writes `Subscriptions::BaseSubscription` and names it in
  `base_types`; without it, the install writes no subscription base.

### Changed

- `@cache`, `@clearCache` and Automatic Persisted Queries use the app's `Rails.cache`
  (`config.cache_store`), as PHP Lighthouse uses Laravel's cache. Outside Rails they use an
  in-memory store.
- `@throttle` is Rails' `rate_limit` on one field, and counts as it does:
  - It counts in the controller's `cache_store` (`config.action_controller.cache_store`,
    `Rails.cache` unless set), under `rate_limit`'s key, `rate-limit:<scope>:<name>:<by>`.
    Counts kept under the old `lighthouse:throttle:` keys start over.
  - `name:` is `rate_limit`'s. Each field counts under its own name (`Query.x`) by default, apart
    from the controller's `rate_limit`, or together with it when both use the same name.
    `prefix:` is `rate_limit`'s `scope:`, the controller's path by default.
  - The client is its IP, as `rate_limit`'s default `by:`, no longer the signed-in user.
  - Past the limit it does what `rate_limit` does by default: it raises
    `ActionController::TooManyRequests`, which Rails answers with a 429
    (`head :too_many_requests` on Rails 7.2). The field used to fail on its own, with the rest of
    the operation answered; that remains the behavior without Action Pack.
- `lighthouse:install` builds on graphql-ruby's `graphql:install`, run with whichever of its
  options the app chose (`--relay`, `--batch`, `--skip-mutation-root-type`, `--schema`,
  `--directory`, `--api`), or run first with its defaults when the app has none. It writes no
  schema class of its own: graphql-ruby's `class AppSchema < GraphQL::Schema` becomes
  `class AppSchema < Lighthouse::GraphQL::RbLightHouse.get_schema(options: { base_types: ... })`,
  naming every class graphql-ruby wrote, and keeps the rest of the class (`use
  GraphQL::Dataloader`, `max_depth`, `id_from_object`, ...). It takes out what Lighthouse replaces:
  the `query(...)` / `mutation(...)` root types the SDL's are built on, the `resolve_type` stub,
  and the example `test_field`. Its base object, interface, union and scalar include
  `Lighthouse::GraphQL::Type`, so every type class is Lighthouse's without an `include` of its
  own. With `--batch`, the schema uses `GraphQL::Dataloader` too. Its `Mutations::BaseMutation`, a
  `RelayClassicMutation`, is kept; graphql-ruby's controller, unchanged since its install, becomes
  one with `Lighthouse::GraphQL::Controller`. `Types::QueryType` and `MutationType` are kept.
- An SDL Mutation field that declares its arguments one by one resolves by convention to a
  `GraphQL::Schema::RelayClassicMutation` subclass as to a plain mutation, its arguments as
  keywords. It used to fail looking for `input:`.
- A subscriptions backend the app's schema class `use`s in its body
  (`use GraphQL::Subscriptions::ActionCableSubscriptions`) delivers the SDL's Subscription fields.
  graphql-ruby adds its subscription extension only to a root type of the class's own.
- `Lighthouse::GraphQL::Controller` puts the controller in the context (`:lighthouse_controller`)
  for `@throttle`. In development, an error Rails answers with a status of its own
  (`config.action_dispatch.rescue_responses`, such as a 429 or a 404) now gets that status, as in
  production, instead of being rendered as a JSON 500.
- `@upload` stores files on the app's ActiveStorage only, with PHP Lighthouse's rules. `disk:`
  names a service of `config/storage.yml` (`config.active_storage.service` without it), and
  `path:` starts the blob's key. ActiveStorage sets visibility per service, so `public:` must now
  agree with the service's: `public: true` on a private service, or the default `false` on a
  public one, fails instead of being ignored. An unknown service, or a value that is not a file,
  fails naming the argument. The file is rewound before it is stored, so a `@validator` may read
  it first.
- The `Upload` scalar's errors are PHP Lighthouse's: a value that is not a file names the GraphQL
  multipart request specification and what was sent instead.

### Removed

- `Config.cache_store`: configure the app's `config.cache_store` instead, and
  `config.action_controller.cache_store` (or a controller's `self.cache_store =`) for `@throttle`.
  `Config.persisted_queries_store` stays, defaulting to `Rails.cache`.
- `Config.upload_store`: to store files elsewhere, declare an ActiveStorage service and name it
  with `@upload(disk:)`, as a Laravel app declares a disk.
- `rails g lighthouse:query` and `lighthouse:mutation`: graphql-ruby has no resolver generator,
  and `graphql:mutation` works in a Lighthouse app now. See Upgrading.

### Fixed

- On graphql-ruby 2.5, a schema using `@limit`, `@bind` or `@upload` without one of their optional
  arguments did not build (`Expected value to not be null`): graphql 2.5 does not apply the default
  of a non-null directive argument. Those arguments (`builder`, `column`, `with`, `optional`,
  `path`, `public`) are nullable now, with the same defaults.

## [0.5.0] - 2026-10-18

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

[Unreleased]: https://github.com/Vaz-Innovation/lighthouse-graphql/compare/v0.8.2...HEAD
[0.8.2]: https://github.com/Vaz-Innovation/lighthouse-graphql/compare/v0.8.1...v0.8.2
[0.8.1]: https://github.com/Vaz-Innovation/lighthouse-graphql/compare/v0.8.0...v0.8.1
[0.8.0]: https://github.com/Vaz-Innovation/lighthouse-graphql/compare/v0.7.3...v0.8.0
[0.7.3]: https://github.com/Vaz-Innovation/lighthouse-graphql/compare/v0.7.2...v0.7.3
[0.7.2]: https://github.com/Vaz-Innovation/lighthouse-graphql/compare/v0.7.1...v0.7.2
[0.7.1]: https://github.com/Vaz-Innovation/lighthouse-graphql/compare/v0.7.0...v0.7.1
[0.7.0]: https://github.com/Vaz-Innovation/lighthouse-graphql/compare/v0.6.0...v0.7.0
[0.6.0]: https://github.com/Vaz-Innovation/lighthouse-graphql/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/Vaz-Innovation/lighthouse-graphql/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/Vaz-Innovation/lighthouse-graphql/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/Vaz-Innovation/lighthouse-graphql/compare/v0.2.1...v0.3.0
[0.2.1]: https://github.com/Vaz-Innovation/lighthouse-graphql/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/Vaz-Innovation/lighthouse-graphql/compare/v0.1.1...v0.2.0
[0.1.1]: https://github.com/Vaz-Innovation/lighthouse-graphql/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/Vaz-Innovation/lighthouse-graphql/releases/tag/v0.1.0
