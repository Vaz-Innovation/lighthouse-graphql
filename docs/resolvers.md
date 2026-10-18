# Resolvers, Mutations and Builders

Most fields need no Ruby: a directive (`@all`, `@find`, `@paginate`, `@create`,
…) or the default attribute reader resolves them. For the rest, Lighthouse looks
up a class by name. There are several kinds of class, and they are not
interchangeable. Each kind has its own contract and its own folder:

| Kind | Folder / namespace | Contract | Used by |
| --- | --- | --- | --- |
| Resolver | `app/graphql/resolvers` · `Resolvers::` | `Resolvers::BaseResolver` (a `GraphQL::Schema::Resolver`) | `Query` fields |
| Mutation | `app/graphql/mutations` · `Mutations::` | `Mutations::BaseMutation` (a `GraphQL::Schema::Mutation`) | `Mutation` fields |
| Subscription | `app/graphql/subscriptions` · `Subscriptions::` | `Subscriptions::BaseSubscription` (a `GraphQL::Schema::Subscription`) | `Subscription` fields ([subscriptions.md](subscriptions.md)) |
| Builder | `app/graphql/builders` · `Builders::` | `call(relation, args, context)` → relation | `@builder` |

Validators (`app/graphql/validators`) are the fourth kind. They are covered in
[validation.md](validation.md).

## Base classes

As in any graphql-ruby app, each of the first three kinds has a base class in its
namespace, and every class of the kind inherits from it:

```ruby
# app/graphql/resolvers/base_resolver.rb
module Resolvers
  class BaseResolver < GraphQL::Schema::Resolver
  end
end

# app/graphql/mutations/base_mutation.rb
module Mutations
  class BaseMutation < GraphQL::Schema::Mutation
  end
end

# app/graphql/subscriptions/base_subscription.rb
module Subscriptions
  class BaseSubscription < GraphQL::Schema::Subscription
    include Lighthouse::GraphQL::Subscription
  end
end
```

What every class of a kind shares goes in its base, once: a concern (as
`BaseSubscription` includes Lighthouse's, see [subscriptions.md](subscriptions.md)),
a helper, graphql-ruby settings such as `argument_class Types::BaseArgument`.
`rails g lighthouse:install` writes the three, and the class generators write the
one they need when it is missing. graphql-ruby's own `graphql:install` writes
`Resolvers::BaseResolver` and `Mutations::BaseMutation` too, and Lighthouse keeps
whatever is already there: an existing base is never replaced.

### Handing the bases to the schema

Name the bases in `base_types`, beside graphql-ruby's own base types, and the
schema holds every class to them:

```ruby
# app/graphql/app_schema.rb
AppSchema = Lighthouse::GraphQL::RbLightHouse.get_schema(
  options: {
    base_types: {
      resolver: Resolvers::BaseResolver,
      mutation: Mutations::BaseMutation,
      subscription: Subscriptions::BaseSubscription
      # object: Types::BaseObject, ... (graphql-ruby's, for the SDL's types)
    }
  }
)
```

- A class a `Query`, `Mutation` or `Subscription` field resolves to, by convention
  or through `@subscription(class:)`, that does not inherit from its kind's base
  raises `Lighthouse::DefinitionError` when the field is first used (`…so it must
  inherit from Resolvers::BaseResolver…`). No class misses what the base shares.
- A `Subscription` field with no class of its own resolves with the subscription
  base, so its concern and settings apply there too.
- A base must be a subclass of the graphql-ruby class of its kind
  (`GraphQL::Schema::Resolver`, `GraphQL::Schema::Mutation`, which
  `RelayClassicMutation` is, `GraphQL::Schema::Subscription`), or the schema does not
  build. graphql-ruby never sees these three keys.

`rails g lighthouse:install` writes the schema class with them. Without them,
Lighthouse requires only the graphql-ruby class (`GraphQL::Schema::Resolver`, …),
and a `Subscription` field with no class resolves with a built-in subscription that
includes the concern.

## Resolvers and mutations: graphql-ruby's contract

A resolver or mutation class is a plain graphql-ruby
[resolver](https://graphql-ruby.org/fields/resolvers.html) or
[mutation](https://graphql-ruby.org/mutations/mutation_classes.html), so everything
you know from graphql-ruby applies:

- the field's arguments arrive as `snake_case` keyword arguments to `resolve`;
- `object` and `context` are available;
- `ready?` and `authorized?` run before `resolve`.

The SDL already declares the field's arguments and return type, so the class
declares neither.

```graphql
type Query {
  latestPosts(limit: Int): [Post!]!
}

type Mutation {
  publishPost(id: ID!): Post
}
```

```ruby
# app/graphql/resolvers/latest_posts.rb
module Resolvers
  class LatestPosts < BaseResolver
    def resolve(limit: 10)
      Post.order(created_at: :desc).limit(limit)
    end
  end
end

# app/graphql/mutations/publish_post.rb
module Mutations
  class PublishPost < BaseMutation
    def authorized?(id:)
      context[:current_user]&.admin? || raise(GraphQL::ExecutionError, 'Admins only.')
    end

    def resolve(id:)
      Post.find(id).tap { |post| post.update!(published: true) }
    end
  end
end
```

### Resolution by convention

A field on `Query` or `Mutation` with **no resolving directive** resolves to the
class named after it, as in PHP Lighthouse:

- `Query.latestPosts` resolves to `Resolvers::LatestPosts`;
- `Mutation.publishPost` resolves to `Mutations::PublishPost`.

The class is looked up on each call, so code reloading works. Classes found by
convention must inherit from `GraphQL::Schema::Resolver` (or `Mutation`, which
is one). Otherwise Lighthouse raises a `Lighthouse::DefinitionError`. A root
field with no class is reported through [`on_error`](configuration.md#on_error):
it raises in test and logs elsewhere. Lighthouse never falls back to a top-level
constant, so a `post` field is never mistaken for the `Post` model.

graphql-ruby's `RelayClassicMutation` (what `rails g graphql:install` makes
`Mutations::BaseMutation` inherit from) works too, as long as the SDL field takes the
`input:` argument it expects.

Wrapping directives (`@guard`, the `@can*` family, `@validator`, `@cache`,
`@clearCache`) are not resolvers, so a field carrying only those still resolves by
convention:

```graphql
type Mutation {
  publishPost(id: ID!): Post @guard @canFind(ability: "publish", find: "id")
}
```

### Naming a class explicitly

`@field(resolver:)` points a field at a class by name. On `Query` and `Mutation`
the name is looked up in the resolvers and mutations namespaces; on any other type,
in [`resolver_namespaces`](configuration.md#resolver_namespaces).

```graphql
type Query {
  feed: [Post!]! @field(resolver: "Feeds::Home")   # Resolvers::Feeds::Home
}
```

Besides graphql-ruby resolver classes, `@field` also accepts a plain callable:
anything with `call(object, args, context)`.

### `@spread` and `@inject`

Both shape the keyword arguments a class receives. They do the same for
[`@create` / `@update`](mutations.md).

```graphql
type Mutation {
  createDraft(input: CreateDraftInput! @spread): Post
    @inject(context: "current_user.id", name: "author_id")
}
```

`resolve(title:, body:, author_id:)` receives the input's fields at the top level.
`author_id` comes from `context[:current_user].id`, so clients cannot set it.
`@inject` is repeatable, and `name:` may be a dot path into an input
(`"input.author_id"`).

## Builders

A builder is not a resolver: it does not produce the field's value. It refines the
query of a field that a model directive resolves. It receives the relation, the
field's arguments and the context, and returns a relation:

```graphql
type Query {
  posts: [Post!]! @paginate @builder(class: "Published")
}
```

```ruby
# app/graphql/builders/published.rb
module Builders
  class Published
    def self.call(relation, args, context)
      relation.where(published: true)
    end
  end
end
```

`@builder` works with `@all`, `@paginate`, `@first`, `@count` and `@aggregate`.
It is repeatable, and `method:` names a method other than `call`. Builder classes
are looked up in the builders namespace only. Raising a `GraphQL::ExecutionError`
from a builder (e.g. a tenancy check) always reaches the client; it never falls
back to the unscoped relation.

The gem ships RBS signatures in `sig/`, so with Steep (or anything that reads
`rbs collection`) a builder can be checked against `Lighthouse::_Builder`:

```rbs
# sig/builders/published.rbs
class Builders::Published
  extend Lighthouse::_Builder
end
```

## Generators

```shell
bin/rails generate lighthouse:query LatestPosts        # app/graphql/resolvers/latest_posts.rb
bin/rails generate lighthouse:mutation PublishPost     # app/graphql/mutations/publish_post.rb
bin/rails generate lighthouse:subscription PostUpdated # app/graphql/subscriptions/post_updated.rb
bin/rails generate lighthouse:builder Published        # app/graphql/builders/published.rb
bin/rails generate lighthouse:validator CreatePostInput # app/graphql/validators/create_post_input_validator.rb
```

Each one writes the class with its contract, into the first namespace configured
for its kind (or `--namespace=…`). A resolver, mutation or subscription inherits
from the namespace's base class, which is written first when it is missing.
Namespaced names nest modules: `lighthouse:mutation Blog::Publish` writes
`Mutations::Blog::Publish < BaseMutation`. These
generators do not collide with graphql-ruby's `graphql:*` generators. A
`lighthouse:mutation` and a `graphql:mutation` of the same name target the same
file, and Rails asks before overwriting it.

## Changing the namespaces

```ruby
Lighthouse.configure do |config|
  config.namespaces = { queries: ['Api::Resolvers'], mutations: ['Api::Mutations'] }
end
```

Kinds you leave out keep their defaults. Each kind takes a list, tried in order.
The `queries` kind is the classes of `Query` fields. Before 0.4.0 it defaulted to
`Queries`; an app keeping its classes in `app/graphql/queries` sets
`config.namespaces = { queries: ['Queries'] }`.
