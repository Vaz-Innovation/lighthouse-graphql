# Resolvers, Mutations and Builders

Most fields need no Ruby: a directive (`@all`, `@find`, `@paginate`, `@create`,
…) or the default attribute reader resolves them. For the rest, Lighthouse looks
up a class by name. There are several kinds of class, and they are not
interchangeable. Each kind has its own contract and its own folder:

| Kind | Folder / namespace | Contract | Used by |
| --- | --- | --- | --- |
| Resolver | `app/graphql/resolvers` · `Resolvers::` | `Resolvers::BaseResolver` (a `GraphQL::Schema::Resolver`) | `Query` fields |
| Mutation | `app/graphql/mutations` · `Mutations::` | `Mutations::BaseMutation` (graphql-ruby's `GraphQL::Schema::RelayClassicMutation`) | `Mutation` fields |
| Subscription | `app/graphql/subscriptions` · `Subscriptions::` | `Subscriptions::BaseSubscription` (a `GraphQL::Schema::Subscription`) | `Subscription` fields ([subscriptions.md](subscriptions.md)) |
| Type | `app/graphql/types` · `Types::` | `Types::BaseObject` (a `GraphQL::Schema::Object`) including `Lighthouse::GraphQL::Type`, named `<Type>Type` | Fields of any object type, through its methods ([type classes](#type-classes), [root type classes](#root-type-classes)); unions, interfaces and scalars too ([types.md](types.md)) |
| Builder | `app/graphql/builders` · `Builders::` | `call(relation, args, context)` → relation | `@builder` |

Validators (`app/graphql/validators`) are one more kind. They are covered in
[validation.md](validation.md).

## Base classes

As in any graphql-ruby app, each kind of class has a base class in its namespace,
and every class of the kind inherits from it. graphql-ruby's `graphql:install`
writes `Resolvers::BaseResolver`, `Mutations::BaseMutation` and the `Types::Base*`
classes, and `rails g lighthouse:install` builds on them: it keeps them as
graphql-ruby wrote them, includes `Lighthouse::GraphQL::Type` in the base object,
interface, union and scalar, and with `--subscriptions` adds
`Subscriptions::BaseSubscription`, which graphql-ruby has none of
([generators.md](generators.md)):

```ruby
# app/graphql/resolvers/base_resolver.rb          (graphql-ruby's)
module Resolvers
  class BaseResolver < GraphQL::Schema::Resolver
  end
end

# app/graphql/mutations/base_mutation.rb          (graphql-ruby's)
module Mutations
  class BaseMutation < GraphQL::Schema::RelayClassicMutation
    argument_class Types::BaseArgument
    field_class Types::BaseField
    input_object_class Types::BaseInputObject
    object_class Types::BaseObject
  end
end

# app/graphql/subscriptions/base_subscription.rb  (Lighthouse's, --subscriptions)
module Subscriptions
  class BaseSubscription < GraphQL::Schema::Subscription
    include Lighthouse::GraphQL::Subscription
  end
end
```

What every class of a kind shares goes in its base, once: a concern (as
`BaseSubscription` includes Lighthouse's, see [subscriptions.md](subscriptions.md)),
a helper, graphql-ruby settings such as `argument_class Types::BaseArgument`. An
existing base is never replaced.

### Handing the bases to the schema

Name the bases in `base_types`, beside graphql-ruby's own base types, and the
schema holds every class to them:

```ruby
# app/graphql/app_schema.rb
class AppSchema < Lighthouse::GraphQL::RbLightHouse.get_schema(
  options: {
    base_types: {
      query_type: Types::QueryType,
      mutation_type: Types::MutationType,
      node: Types::NodeType,
      resolver: Resolvers::BaseResolver,
      mutation: Mutations::BaseMutation,
      subscription: Subscriptions::BaseSubscription,
      object: Types::BaseObject,
      interface: Types::BaseInterface,
      union: Types::BaseUnion,
      scalar: Types::BaseScalar,
      enum: Types::BaseEnum,
      input_object: Types::BaseInputObject
    }
  }
)
  use GraphQL::Dataloader
end
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
- `query_type:` and `mutation_type:` are the code-first classes the SDL's `Query`
  and `Mutation` are built on (see [root type classes](#root-type-classes)), and
  `node:` is the SDL's `Node` interface ([relay.md](relay.md#relay-through-graphql-ruby)).
  `subscription_type:` does the same for `Subscription`.
- The others are graphql-ruby's: it builds the SDL's types of each kind from them.
  A [type class](#type-classes) (one including `Lighthouse::GraphQL::Type`) that
  does not inherit from its kind's raises `Lighthouse::DefinitionError` when the
  schema is built.

`rails g lighthouse:install` names in the schema class every one graphql-ruby's
install wrote. Without them,
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

A field on `Query` or `Mutation` with **no resolving directive**, and no method of
its name on the [root type class](#root-type-classes), resolves to the class named
after it, as in PHP Lighthouse:

- `Query.latestPosts` resolves to `Resolvers::LatestPosts`;
- `Mutation.publishPost` resolves to `Mutations::PublishPost`.

The class is looked up on each call, so code reloading works. Classes found by
convention must inherit from `GraphQL::Schema::Resolver` (or `Mutation`, which
is one). Otherwise Lighthouse raises a `Lighthouse::DefinitionError`. A root
field with no class is reported through [`on_error`](configuration.md#on_error):
it raises in test and logs elsewhere. Lighthouse never falls back to a top-level
constant, so a `post` field is never mistaken for the `Post` model.

graphql-ruby's `RelayClassicMutation`, which `Mutations::BaseMutation` inherits from,
takes a single `input:` argument. A `Mutation` field whose SDL declares its arguments
one by one calls the class as a plain mutation, with those arguments as keywords
(`resolve(id:)` above). A field with a single `input:` argument goes through
`RelayClassicMutation`'s own `input:` handling.

Wrapping directives (`@guard`, the `@can*` family, `@validator`, `@cache`,
`@clearCache`) are not resolvers, so a field carrying only those still resolves by
convention:

```graphql
type Mutation {
  publishPost(id: ID!): Post @guard @canFind(ability: "publish", find: "id")
}
```

### Root type classes

graphql-ruby's install writes `Types::QueryType` and `Types::MutationType`, and the
schema's `base_types` name them (`query_type:`, `mutation_type:`). The SDL's `Query`
and `Mutation` are built on them, so they work as in a graphql-ruby app:

- A root field with no resolving directive calls the method of its snake_case name
  on the class, when the class defines it and includes `Lighthouse::GraphQL::Type`
  (`Types::BaseObject` does, after `lighthouse:install`). It comes before the
  conventional class: `Query.latestPosts` calls `Types::QueryType#latest_posts`
  before `Resolvers::LatestPosts`.
- The class's own `field`s are the schema's too, beside the SDL's, and resolve as
  in graphql-ruby: Relay's `node` / `nodes`, and the `field :publish_post, mutation:
  Mutations::PublishPost` that `rails g graphql:mutation` adds. An SDL field of the
  same name wins.
- When the SDL has no `Mutation` type, `Types::MutationType` itself is the root,
  once it declares a field.

```graphql
type Query {
  latestPosts(limit: Int = 10): [Post!]!
}
```

```ruby
# app/graphql/types/query_type.rb
module Types
  class QueryType < Types::BaseObject
    def latest_posts(limit:)
      Post.order(created_at: :desc).limit(limit)
    end
  end
end
```

As in a [type class](#type-classes), the method has `object`, `context`, the
`dataload*` helpers and `resolve_info`, and gets the field's arguments as snake_case
keywords. `Subscription` fields resolve with their classes, as before.

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
anything with `call(object, args, context)`, and `call(object, args, context,
resolve_info)` when it takes a fourth argument.

A method after `@` (PHP Lighthouse's `Class@method`) replaces `call`, or `resolve` on
a resolver class (whose `authorized?` still runs). One class can then hold several
fields' resolvers:

```graphql
type Query {
  counts: Counts! @field(resolver: "Statistics@counts")
  latest: [Post!]! @field(resolver: "Statistics@latest")
}
```

```ruby
class Resolvers::Statistics
  def self.counts(_root, _args, _context) = { posts: Post.count, users: User.count }
  def self.latest(_root, _args, _context) = Post.order(created_at: :desc).limit(5)
end
```

### ResolveInfo

What PHP Lighthouse hands a resolver as `$resolveInfo`. A `Resolvers::` or
`Mutations::` class, a class `@field` names and a type class's methods read it as
`resolve_info`:

| | |
| --- | --- |
| `field_name`, `field`, `return_type` | the field being resolved |
| `parent_type` | the type it belongs to |
| `object`, `arguments`, `context` | what it resolves with |
| `path` | `["posts", 0, "author"]` |
| `lookahead` | graphql-ruby's [`Lookahead`](https://graphql-ruby.org/queries/lookahead.html): what the client selects below the field (`lookahead.selects?(:author)`) |
| `enhance_builder(relation, scopes: [])` | `relation` with the field's query directives applied |

`enhance_builder` lets a class build the query no directive could, and still honour
what the field declares: its `@builder` classes, and the argument directives the
client used (`@eq`, `@where`, `@in`, `@like`, `@orderBy`, `@whereConditions`, ...),
then the field's own `@orderBy(column:)`, as `@all` and `@paginate` apply them. `scopes:` adds model scopes.
When the client searches ([`@search`](filtering-and-ordering.md#in-a-resolver-of-your-own)), it searches
too: with pg_search the answer is still a relation, with Searchkick a `Lighthouse::Search::Result`
(`records(first:, offset:)`, `count`), for which the relation must select what the model's own does
(`Post.all`, or `Post`): any other is refused, as the engine would drop its conditions.
A field your class resolves may search with Searchkick this way, whatever its type.

```graphql
type Query {
  myPosts(title: String @like, orderBy: _ @orderBy(columns: ["title", "created_at"])): [Post!]! @guard
}
```

```ruby
class Resolvers::MyPosts < Resolvers::BaseResolver
  def resolve(**)
    resolve_info.enhance_builder(context[:current_user].posts, scopes: [:recent])
  end
end
```

### Fields of other types

A field of any other type resolves with the default reader: `Post.commentsCount`
reads `post.comments_count`. When its value takes more than reading an attribute
or calling a method ([`@method`](directives.md#method)), name a class with
`@field`. The class is a resolver like the ones above, and its `object` is the
**parent**: the record the field belongs to (PHP Lighthouse's `$root`). It
resolves wherever the type appears in a response: in a list, under a
relationship, or under another class's result.

```graphql
type Post {
  tagsCount: Int! @field(resolver: "Posts::TagsCount")
  excerpt(length: Int = 80): String @field(resolver: "Posts::Excerpt")
}
```

```ruby
# app/graphql/resolvers/posts/tags_count.rb
module Resolvers
  module Posts
    class TagsCount < BaseResolver
      def resolve
        dataload_association(object, :tags).size
      end
    end
  end
end

# app/graphql/resolvers/posts/excerpt.rb
module Resolvers
  module Posts
    class Excerpt < BaseResolver
      def resolve(length:)
        object.body&.truncate(length, separator: ' ')
      end
    end
  end
end
```

```graphql
{
  posts(first: 10) { data { title tagsCount excerpt(length: 40) } }
}
```

The field's arguments arrive as keyword arguments, with the SDL's default when the
client leaves one out, as on a root field. The class runs once per parent, so load
anything beyond the parent's own columns through graphql-ruby's dataloader
(`dataload_association`, `dataload_record`, or a `GraphQL::Dataloader::Source` of
your own). Then listing ten posts runs one query for their tags, not ten.

A field can also resolve with a method of its type's class, as in a graphql-ruby
app. See [type classes](#type-classes), next: they suit a field that only the type
needs, and a class named by `@field` suits one with its own logic, its own
arguments, or that you want to find in the schema.

On these types the name is looked up in the resolvers namespace first, a nested
name too, so `Posts::TagsCount` is `Resolvers::Posts::TagsCount`, kept in
`app/graphql/resolvers/posts/`. A folder per type keeps these classes apart from
the `Query` ones. Name it in the plural (`Posts`): a `Resolvers::Post` module would
hide the `Post` model from code written inside `module Resolvers`. When the
resolvers namespace has no such class, the name is looked up in
[`resolver_namespaces`](configuration.md#resolver_namespaces), and a full name
(`Resolvers::Posts::TagsCount`) works as well. The schema's `base_types` are not
enforced here, but inheriting from `Resolvers::BaseResolver` still gives the class
what every resolver shares.

### Type classes

graphql-ruby keeps the Ruby side of each object type in `app/graphql/types`:
`Types::PostType`, inheriting from `Types::BaseObject`, as `rails g graphql:object
Post` writes it. Lighthouse keeps that structure. A type class that includes
`Lighthouse::GraphQL::Type` is handed to Lighthouse. After `lighthouse:install`,
`Types::BaseObject` includes it, so every type class does: the SDL still declares the type and its fields, and the class says how
the fields with no resolving directive resolve. A field calls the method of its
snake_case name, when the class defines it. Fields it does not define are read off
the object, as before, and fields with a resolving directive keep it.

That makes a type that is not a model as easy to resolve as a model's: the parent
returns any object (a Hash, a Struct, a client's response), and the type's class
reads or computes each field from it.

```graphql
type Post {
  title: String!
  readingTime: ReadingTime!
}

type ReadingTime {
  words: Int!
  minutes(wordsPerMinute: Int = 200): Int!
}
```

```ruby
# app/graphql/types/post_type.rb
module Types
  class PostType < BaseObject
    def reading_time
      { words: object.body.to_s.split.size }
    end
  end
end

# app/graphql/types/reading_time_type.rb
module Types
  class ReadingTimeType < BaseObject
    def minutes(words_per_minute:)
      [(object[:words] / words_per_minute.to_f).ceil, 1].max
    end
  end
end
```

`Post.title` is the model's column. `Post.readingTime` calls
`Types::PostType#reading_time`. `ReadingTime.words` is read off the Hash it
returns, and `ReadingTime.minutes` calls `Types::ReadingTimeType#minutes`.

As in graphql-ruby, the class is instantiated per parent, so a method has:

- `object`: the parent, here the post;
- `context`: the query's context;
- the field's arguments, as snake_case keywords, with the SDL's default when the
  client leaves one out;
- graphql-ruby's `dataload`, `dataload_record` and `dataload_association`, to load
  anything beyond the parent's own columns without N+1.

Wrapping directives (`@guard`, `@can*`, `@cache`) on the field run around the
method. A method every `GraphQL::Schema::Object` has (`object`, `context`) never
resolves a field.

#### The model

The type's model is the SDL's to say, as in PHP Lighthouse: a type named after its
model needs nothing, and [`@model`](directives.md#model) maps one that is not:

```graphql
type Article @model(class: "Post") {
  title: String!
  headline: String!
}
```

`Types::ArticleType`'s methods then only ever run on a `Post`: a parent of another
class (a Hash a resolver returned by mistake, another model) is reported through
[`on_error`](configuration.md#on_error), which raises in test, and the field
resolves to `null`. `@model` also gives `@all`, `@find`, `@paginate`, `@create`... on
fields returning `Article` their model, and resolves a `Post` in a union or
interface to `Article` ([types.md](types.md#the-default)).

#### Opting in

The class is the type's name plus `Type`, looked up in `namespaces[:types]`
(default `['Types']`) when the schema is built. Only a class that includes
`Lighthouse::GraphQL::Type` counts: any other `Types::PostType` is left alone, and
its methods resolve nothing. `lighthouse:install` includes the concern in
`Types::BaseObject`, `BaseInterface`, `BaseUnion` and `BaseScalar`, which hands every
type class over at once. In an app that did not run it, include the concern in
those bases, or in each type class (`include Lighthouse::GraphQL::Type`).

A class that includes the concern must inherit from the schema's
`base_types[:object]` when one is given, or the schema does not build. The concern
also hands over the classes of unions, interfaces and scalars, which pick the type
of a union's values or coerce a scalar's: see [types.md](types.md). It is not the schema's type: it only lends its
methods. Fields are declared in the SDL, so `field` declarations in it are ignored,
and graphql-ruby's type-level `authorized?` does not run; authorize with
[`@can*`](authorization.md). `Query` and `Mutation` are the exception: they are
built on their [root type classes](#root-type-classes), whose `field`s count.
`Subscription` fields resolve with their own classes.

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
bin/rails generate lighthouse:subscription PostUpdated # app/graphql/subscriptions/post_updated.rb
bin/rails generate lighthouse:builder Published        # app/graphql/builders/published.rb
bin/rails generate lighthouse:validator CreatePostInput # app/graphql/validators/create_post_input_validator.rb
bin/rails generate graphql:object Post                 # a type class, Lighthouse's through Types::BaseObject
bin/rails generate graphql:mutation PublishPost        # a code-first mutation, a field of Types::MutationType
```

Each Lighthouse generator writes the class with its contract, into the first
namespace configured for its kind (or `--namespace=…`). Type classes come from
graphql-ruby's own `graphql:object`, `graphql:scalar`, `graphql:union` and
`graphql:interface`. A resolver class has no generator, as in graphql-ruby: write
it by hand, as above. [generators.md](generators.md) has what each generator writes,
and which of graphql-ruby's fit a Lighthouse app.

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
