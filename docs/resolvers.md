# Queries, Mutations and Builders

Most fields need no Ruby: a directive (`@all`, `@find`, `@paginate`, `@create`,
…) or the default attribute reader resolves them. For the rest, Lighthouse looks
up a class by name. There are three kinds of class, and they are not
interchangeable. Each kind has its own contract and its own folder:

| Kind | Folder / namespace | Contract | Used by |
| --- | --- | --- | --- |
| Query | `app/graphql/queries` · `Queries::` | `GraphQL::Schema::Resolver` | `Query` fields |
| Mutation | `app/graphql/mutations` · `Mutations::` | `GraphQL::Schema::Mutation` | `Mutation` fields |
| Builder | `app/graphql/builders` · `Builders::` | `call(relation, args, context)` → relation | `@builder` |

Validators (`app/graphql/validators`) are the fourth kind. They are covered in
[validation.md](validation.md).

## Queries and mutations: graphql-ruby's contract

A query or mutation class is a plain graphql-ruby
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
# app/graphql/queries/latest_posts.rb
module Queries
  class LatestPosts < GraphQL::Schema::Resolver
    def resolve(limit: 10)
      Post.order(created_at: :desc).limit(limit)
    end
  end
end

# app/graphql/mutations/publish_post.rb
module Mutations
  class PublishPost < GraphQL::Schema::Mutation
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

- `Query.latestPosts` resolves to `Queries::LatestPosts`;
- `Mutation.publishPost` resolves to `Mutations::PublishPost`.

The class is looked up on each call, so code reloading works. Classes found by
convention must inherit from `GraphQL::Schema::Resolver` (or `Mutation`, which
is one). Otherwise Lighthouse raises a `Lighthouse::DefinitionError`. A root
field with no class is reported through [`on_error`](configuration.md#on_error):
it raises in test and logs elsewhere. Lighthouse never falls back to a top-level
constant, so a `post` field is never mistaken for the `Post` model.

graphql-ruby's `RelayClassicMutation` (what `rails g graphql:install` generates
`Mutations::BaseMutation` from) works too, as long as the SDL field takes the
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
the name is looked up in the queries and mutations namespaces; on any other type,
in [`resolver_namespaces`](configuration.md#resolver_namespaces).

```graphql
type Query {
  feed: [Post!]! @field(resolver: "Feeds::Home")   # Queries::Feeds::Home
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

## Generators

```shell
bin/rails generate lighthouse:query LatestPosts        # app/graphql/queries/latest_posts.rb
bin/rails generate lighthouse:mutation PublishPost     # app/graphql/mutations/publish_post.rb
bin/rails generate lighthouse:builder Published        # app/graphql/builders/published.rb
bin/rails generate lighthouse:validator CreatePostInput # app/graphql/validators/create_post_input_validator.rb
```

Each one writes the class with its contract, into the first namespace configured
for its kind (or `--namespace=…`). Namespaced names nest modules:
`lighthouse:mutation Blog::Publish` writes `Mutations::Blog::Publish`. These
generators do not collide with graphql-ruby's `graphql:*` generators. A
`lighthouse:mutation` and a `graphql:mutation` of the same name target the same
file, and Rails asks before overwriting it.

## Changing the namespaces

```ruby
Lighthouse.configure do |config|
  config.namespaces = { queries: ['Api::Queries'], mutations: ['Api::Mutations'] }
end
```

Kinds you leave out keep their defaults. Each kind takes a list, tried in order.
