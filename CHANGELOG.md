# Changelog

All notable changes to `lighthouse-graphql` are documented here. The format is
based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and this
project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
- `@cacheControl(maxAge:, scope:, inheritMaxAge:)` computes the response's `Cache-Control`
  header from the selected fields (PHP Lighthouse's / Apollo's rules);
  `Lighthouse::GraphQL::CacheControl.apply(response, result)` sets it, and the generated
  controller calls it.

### Fixed

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

[Unreleased]: https://github.com/Vaz-Innovation/lighthouse-graphql/compare/v0.1.1...HEAD
[0.1.1]: https://github.com/Vaz-Innovation/lighthouse-graphql/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/Vaz-Innovation/lighthouse-graphql/releases/tag/v0.1.0
