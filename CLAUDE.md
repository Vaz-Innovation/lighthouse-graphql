# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

`lighthouse-graphql` is a Ruby gem: a port of PHP Lighthouse to Rails, built on graphql-ruby (`~> 2.5`). Apps write SDL with server-side directives (`@all`, `@find`, `@paginate`, `@hasMany`, `@whereConditions`, `@can*`, `@cache`, …) instead of hand-writing resolvers. It also supports Apollo Federation subgraphs.

## Commands

```bash
bundle exec rspec                                   # gem suite (in-memory SQLite, no DB server needed)
bundle exec rspec spec/lighthouse/find_spec.rb      # one file
bundle exec rspec spec/lighthouse/find_spec.rb:42   # one example
bundle exec rubocop                                 # lints the gem AND example/ (-a to autocorrect)
bundle exec rake rbs                                # rbs:validate + rbs:test (suite run with every Lighthouse::* method checked against sig/)
bundle exec rake build                              # package into pkg/
bundle exec rake                                    # default: spec, rubocop, rbs

# End-to-end suite: a Rails 8.1 app using the gem from this checkout (path: '..')
cd example && bundle install && bin/rails db:test:prepare && bundle exec rspec
cd example && bin/rails lighthouse:persisted_queries:verify
# The same suite on PostgreSQL / MySQL (and Redis for @throttle): see example/README.md
cd example && DATABASE_URL=postgres://... REDIS_URL=redis://... bundle exec rspec

# Docs site (VuePress, built from docs/)
cd website && npm install && npm run dev
```

Before a PR, CI expects: the gem suite, RuboCop, `rake rbs`, the example's specs, and `rake build` all green. CI runs the suite on Ruby 3.1–3.4.

There is deliberately no root `Gemfile.lock` (a library resolves against its gemspec). Don't add one. `example/` does have its own lockfile.

## Architecture

### Schema build pipeline

`RbLightHouse.get_schema` → `SchemaFactory.build_base_schema` → `SchemaGenerator.build`:

1. **Load**: `SDLLoader` merges every `.graphql` file in the SDL folder.
2. **Manipulation phase** (SDL string → SDL string): `inject_directive_definitions` prepends `directive @x` definitions (and the types they reference) for any registered directive the SDL uses but doesn't declare. Then every registered SDL manipulator runs in order (`PaginationManipulator` adds Paginator/Connection types, `WhereConditionsDirective` adds the `where:` input types). The result can be cached on disk via `SchemaCache`.
3. **Build**: `GraphQL::Schema.from_definition` with a prebuilt parser, so the document isn't parsed again. `SchemaImplementation` is the `default_resolve`.
4. **Resolution phase** (`post_process`): for each object field, `FieldResolverStack.apply` installs resolvers from the field's directives. Each one defines a singleton `resolve_field_<name>` on the type.
5. **Runtime dispatch**: `GeneratedResolvers.install_dispatcher` and `route_runtime_resolver` make graphql-ruby call those singletons. Otherwise the default reader returns the object's attribute (camelCase field → snake_case attribute via `Support::Naming`) or a Hash key.

`GeneratedResolvers.generated?` only recognises a `resolve_field_*` method whose `source_location` contains `/lib/lighthouse/`. graphql-ruby defines methods with the same names internally. So resolver-defining code must live under `lib/lighthouse/`.

### Directives

- `lib/lighthouse/directives/registry.rb` (`Lighthouse::DirectiveRegistry`) is the hub. It maps names to resolver classes, arg-builder classes (`@eq`, `@in`, `@where`, `@orderBy`, …), SDL manipulators, and injected definitions. Read it and `directive_resolvers/base.rb` first.
- **Resolution order:** `RESOLUTION_ORDER` controls it. Wrappers (order > 0) are `guard`/`auth` (5), `can*` (4), `validator` (3), `cache` (2) and `clearCache` (1). Each wrapper captures the field's existing resolver through `capture_inner` / `Resolution.capture` and decorates it. Data resolvers are order 0 and are applied first, innermost.
- **Convention resolver:** a root `Query`/`Mutation` field with no resolving directive falls back to `ConventionResolver`. For example, `Query.latestPosts` resolves to `Resolvers::LatestPosts`, a `GraphQL::Schema::Resolver` (by graphql-ruby's convention, a `Resolvers::BaseResolver`). The schema's `base_types` can name the bases (`resolver:`, `mutation:`, `subscription:`; see `resolver_bases.rb`), which Lighthouse then enforces. The namespaces come from `Config.namespaces` and are looked up at call time, so code reloading works.
- **Type classes:** on any other object type, a field with no resolving directive calls the method of its snake_case name on `Types::<Type>Type` (graphql-ruby's `app/graphql/types` structure, `Config.namespaces[:types]`) when that class includes `Lighthouse::GraphQL::Type` (`lib/lighthouse/type.rb`) and defines it: `TypeMethodResolver`, installed by `FieldResolverStack`. Classes without the concern are ignored. The class only lends methods; the SDL still declares the fields. A type's model is the SDL's `@model(class:)`: `ModelDirective` injects `model:` into the model directives of fields returning it (an SDL manipulator, first in line).
- **Unions, interfaces, scalars:** graphql-ruby asks the schema's `default_resolve` object for fields, `resolve_type` and scalar coercion. `DefaultResolveDispatcher` (installed by `GeneratedResolvers.install_dispatcher`) answers fields and must keep handing the other two to `SchemaImplementation`. `TypeResolution` picks a union's/interface's object type (`@union`/`@interface`, the type class's `resolve_type`, then class name / `model`); `ScalarCoercion` installs a scalar's class's `coerce_*` on the scalar type at build. Guide: `docs/types.md`.
- **Argument directives** run in two phases (`ArgumentTransformsResolver`, installed by `FieldResolverStack#argument_steps`): rewriting ones (`@globalId`, `@trim`, `@drop`) outermost, effectful ones (`@hash`, `@bind`, `@upload`) after `@guard`/`@can*`/`@validator`. Keep side effects out of the outer phase.
- **ResolveInfo:** `ResolverDispatch.call(klass, info, method:)` takes a `ResolveInfo` (field, parent type, object, args, context), which classes read as `resolve_info` and plain callables get as a 4th argument when they take one. `enhance_builder` applies a field's `@builder` and arg-builder directives to any relation.
- **Contracts:** `lib/lighthouse/contracts/` defines what a resolver class can implement: `FieldResolver`, `FieldMiddleware`, `FieldManipulator`, `ArgManipulator` and `ArgBuilder`. The registry classifies each class by which contract it includes.
- **Batching:** relationship directives batch through graphql-ruby's Dataloader (`dataloader_sources/`, `relation_batch.rb`).
- **Nested mutations:** `nested_mutations/` handles create/update/upsert/connect operations on every association kind.

### Adding a directive

You don't need to edit the generator:

1. Write the resolver in `lib/lighthouse/directive_resolvers/`.
2. Register it in `registry.rb`. Give it an entry in `RESOLUTION_ORDER` if it wraps another resolver.
3. Spec it with the SDL helpers in `spec/support/schema_builders.rb` (`build_schema`, `build_federated_schema`).
4. Document it in `docs/directives.md` and in any matching family page under `docs/`. Per CONTRIBUTING, "a directive that is not in `docs/` does not exist".

## Conventions and gotchas

- **Requiring new files:** `lib/lighthouse/rb_lighthouse.rb` requires every file explicitly, from a list. A new file must be added to that list. A `LoadError` only produces a warning, so a missing entry fails quietly.
- **Compact class definitions:** files open their class compactly (`class Lighthouse::GraphQL::DirectiveResolvers::Foo`), so lexical constant lookup doesn't see the enclosing namespaces. Refer to other constants by their full name (`Lighthouse::Support::Naming`, `::GraphQL::Schema`). Declare new namespaces in `lib/lighthouse/namespaces.rb`.
- **Config:** `Lighthouse::Config` holds every setting. A new setting must be added to `SETTINGS`, or `reset!` won't clear it between specs (`spec_helper` calls `reset!` after each example).
- **RBS signatures:** `sig/` ships with the gem and covers the public API: config, extension points and entrypoints. Update it when you change those, because `rake rbs` checks the signatures against real calls made during the suite.
- **Gem packaging:** `spec.files` in the gemspec is an explicit `Dir[...]` allowlist. CI fails if a tracked file under `lib`, `sig` or `docs` is missing from the built gem.
- **graphql-ruby patches:** `graphql_ruby_patches.rb` patches graphql-ruby's private internals defensively. If a patch can't apply, it is skipped rather than failing.
- **Tests:** specs build a real schema from inline SDL and run real queries against ActiveRecord models (`Widget` and `Post` in `spec_helper.rb`, plus `spec/support/lighthouse_models.rb`). A regression spec should be the SDL that broke. Put a spec in `example/spec/` when a feature depends on Rails itself: requests, headers, the reloader or rake tasks.
- **Docs site:** `docs/*.md` ships in the gem and is published by `website/`. A new guide needs a sidebar entry in `website/.vuepress/config.js`.
- **Commits and changelog:** use Conventional Commits (`feat(directives): …`, `fix(paginate): …`). Add user-facing changes under `## [Unreleased]` in `CHANGELOG.md`.
- **Releases:** bump `lib/lighthouse/graphql/version.rb`, move the Unreleased entries into a dated section, then tag `vX.Y.Z`. The Release workflow publishes to RubyGems.
