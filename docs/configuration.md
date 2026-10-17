# Configuration

Configure Lighthouse from a single initializer. Keeping app-specific wiring here
means the library holds no app constants — which is what makes it cleanly
reusable and publishable.

```ruby
# config/initializers/lighthouse.rb
require 'lighthouse-graphql'

Lighthouse.configure do |config|
  config.sdl_folder = Rails.root.join('graphql').to_s
  config.resolver_namespaces = ['App::Graphql', 'Resolvers']
  config.on_error = ->(error, _context) { Rails.error.report(error) }
end
```

## Options

### `sdl_folder`

Where Lighthouse loads `*.graphql` files from. Defaults to `RAILS_ROOT/graphql`
in a Rails app, `nil` otherwise (pass SDL explicitly via `SchemaFactory` when not
on Rails).

### `resolver_namespaces`

An ordered list of namespaces tried when resolving a **class name** referenced by
a directive argument — `@field(resolver: "ContactPerson")`, `@all(model: "User")`,
`@builder(class: "ContactsBuilder")`. Fully-qualified names (containing `::`) are
used as-is. Defaults to `['App::Graphql']`.

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

## Federation reference resolvers

Custom federation entity resolvers are registered with
`Lighthouse::ReferenceResolver` (see [federation.md](federation.md)), typically in
`config/initializers/federation.rb` so they re-register on code reload:

```ruby
Rails.application.config.to_prepare do
  Lighthouse::ReferenceResolver.register('User') { |ref, _ctx| User.find_by(id: ref['id']) }
end
```
