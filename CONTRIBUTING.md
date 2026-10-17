# Contributing to lighthouse-graphql

Thanks for taking the time. Lighthouse is a directive vocabulary before it is a codebase: most
changes are "add a directive" or "make an existing directive handle one more shape", and both
have a well-worn path through the repository.

## Getting started

```bash
git clone https://github.com/YOUR_USERNAME/lighthouse-graphql.git
cd lighthouse-graphql
bundle install
```

Ruby 3.0 or newer, as the gemspec requires. No database server is needed: the suite runs
ActiveRecord against in-memory SQLite.

```bash
bundle exec rspec                    # the whole suite
bundle exec rspec spec/lighthouse/federation_spec.rb
bundle exec rubocop                  # lint the gem and the example app (-a to autocorrect)
bundle exec rake build               # package the gem into pkg/
bundle exec rake                     # default task — the suite, then RuboCop

cd example && bundle install && bin/rails db:prepare && bundle exec rspec   # end-to-end suite
```

**There is no committed `Gemfile.lock`, deliberately.** A library resolves against its
gemspec; pinning a lockfile would freeze every contributor and every CI run to whichever Ruby
and platform happened to write it. CI resolves fresh on each Ruby in the matrix, which is the
point — it is how a `>= 6.0` dependency bound gets tested rather than asserted.

## How the library is laid out

```
lib/lighthouse/
  graphql.rb                  entry point and public surface
  namespaces.rb               the modules every other file opens compactly
  config.rb                   Lighthouse.configure — resolver namespaces, on_error
  schema_generator.rb         SDL -> graphql-ruby classes; the heart of the build
  schema_factory.rb           assembles the generated types into a Schema
  sdl_loader.rb               reads and merges the .graphql files
  directives/
    registry.rb               name -> resolver dispatch; where a new directive registers
    arguments/                @eq, @in, @like, @where… the arg-level filters
  directive_resolvers/        one class per directive: @all, @find, @paginate, @hasMany…
  contracts/                  the interfaces a resolver can implement
  dataloader_sources/         batching for relationships, via graphql-ruby's Dataloader
  reference_resolver.rb       Apollo Federation entity resolution
```

The two files worth reading before anything else are `directives/registry.rb` and
`directive_resolvers/base.rb`. Everything else hangs off them.

### Adding a directive

The registry exists so this is additive — the generator is not edited:

1. Write a resolver under `lib/lighthouse/directive_resolvers/`, implementing whichever
   contract fits (`FieldResolver` for something that produces a value, `FieldMiddleware` to
   wrap one, `FieldManipulator` / `ArgManipulator` to change the schema itself).
2. Register it in `lib/lighthouse/directives/registry.rb`.
3. Spec it in `spec/lighthouse/`, building a schema from SDL with the helpers in
   `spec/support/schema_builders.rb` — that is how every other directive is tested, and it
   keeps the test honest about what a user actually writes.
4. Document it in `docs/directives.md`, and in the matching page under `docs/` if it belongs
   to a family (`docs/relationships.md`, `docs/filtering-and-ordering.md`, …).

A directive that is not in `docs/` does not exist as far as users are concerned — the docs are
the interface.

### Code style

`.rubocop.yml` is the style guide; CI runs it. Files open their class compactly,
`class Lighthouse::GraphQL::DirectiveResolvers::BaseDirectiveResolver`, so lexical
lookup does not see the enclosing namespaces: refer to other constants by their full
name (`Lighthouse::Support::Naming`, `::GraphQL::Schema`). A new namespace goes in
`lib/lighthouse/namespaces.rb`.

## Testing

Specs build a real schema from SDL and execute real queries against real ActiveRecord models.
That is slower than unit-testing a resolver in isolation and worth it: the bugs in a library
like this one live in the seam between SDL, graphql-ruby's type system, and the database, and
only an end-to-end query crosses all three.

When you fix a bug, the regression spec should be the SDL that broke it.

[`example/`](./example) is a Rails app using the gem from this checkout, and its specs
are the end-to-end suite: they go through the app's real `/graphql` endpoint, with its
controller, policies, cache store and generated classes. Add one there when a feature
depends on Rails itself (requests, headers, the reloader, rake tasks), and keep the
app a readable example: it is also what users look at to see how the pieces fit.

## Commits

[Conventional Commits](https://www.conventionalcommits.org/):

```
feat(directives): add @whereHasConditions for nested relation filters
fix(paginate): keep the connection type when the field is also renamed
docs(federation): show the @key + ReferenceResolver pairing
```

Types: `feat`, `fix`, `docs`, `style`, `refactor`, `test`, `chore`.

## Pull requests

1. Rebase on `main`.
2. `bundle exec rspec`, `bundle exec rubocop`, the example's `bundle exec rspec` and
   `bundle exec rake build` — all green.
3. Add a note under `## [Unreleased]` in [CHANGELOG.md](./CHANGELOG.md), written for someone
   deciding whether to upgrade.
4. Open the PR and say which Ruby you ran against.

## Releasing

Maintainers only.

1. Move the `## [Unreleased]` entries into a `## [x.y.z] - YYYY-MM-DD` section, and update the
   link references at the bottom of the file.
2. Bump `VERSION` in `lib/lighthouse/graphql/version.rb`.
3. Commit, then tag: `git tag -a vx.y.z -m "vx.y.z" && git push --follow-tags`.

The `Release` workflow builds, runs the suite, refuses if the tag and the gem version disagree,
pushes to RubyGems, and creates the GitHub Release from that version's changelog section — so
the notes on GitHub and the notes in the repository cannot drift apart.

It asks RubyGems whether the version is already published and skips the push if it is, which
makes the whole workflow re-runnable: RubyGems refuses to overwrite a version, so without that
check a release that failed *after* the push could never be re-run to completion.

### How the push authenticates

Two modes, decided by whether a `RUBYGEMS_API_KEY` secret exists on the repository:

- **No secret — trusted publishing (preferred).** The workflow exchanges its GitHub OIDC token
  for a short-lived RubyGems credential. Nothing long-lived is stored anywhere. It needs a
  one-time setup on rubygems.org, under the gem's *Trusted publishers*: this repository,
  workflow `release.yml`. A gem that does not exist yet can be registered as a *pending*
  trusted publisher, so this works for a first release too.
- **With a `RUBYGEMS_API_KEY` secret.** The workflow pushes with that key instead. Note that
  the gemspec sets `rubygems_mfa_required`, so the key has to be one RubyGems accepts for
  MFA-required gems.

Publishing by hand is the same thing without the workflow:

```bash
bundle exec rake build
gem push pkg/lighthouse-graphql-x.y.z.gem   # asks for your OTP
```
