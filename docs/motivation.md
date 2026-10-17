# Motivation

Lighthouse GraphQL Rails brings the ideas of [Lighthouse](https://lighthouse-php.com),
the GraphQL framework for Laravel, to Ruby on Rails. This page explains those ideas:
why the schema comes first, why behaviour lives in directives, and why that works so
well on top of an opinionated model layer like Active Record.

## Where it comes from

Lighthouse ([nuwave/lighthouse](https://github.com/nuwave/lighthouse)) changed how many
Laravel teams build GraphQL APIs. Instead of a resolver class for every field, you write
the schema in GraphQL's own language and attach **directives** that say what a field
does: `@paginate` it, follow a `@hasMany` relationship, `@create` a model, check a policy
with `@canFind`. Lighthouse reads those directives and generates efficient queries against
Eloquent, Laravel's ORM.

The idea does not depend on PHP. It depends on two things: a schema written first, and a
model layer with strong conventions. Rails has the second in Active Record, and
[graphql-ruby](https://graphql-ruby.org) gives Ruby a mature GraphQL engine to build the
first on. Lighthouse GraphQL Rails puts them together. It keeps Lighthouse's directive
names, arguments and error formats wherever they make sense, so its documentation, its
examples and the experience of Laravel teams carry over.

## The problem with writing every resolver

Most GraphQL fields in a Rails app do one of a handful of things: list records, find one,
paginate, follow an association, filter and sort, read an attribute, or create, update
and delete a record. Written by hand, each of these is a resolver. Each resolver is a
place where:

- **the API's shape hides in Ruby.** To know what `posts` accepts and returns, you read
  a type class, its fields, their resolver methods and the scopes they call.
- **N+1 queries creep in.** Every association needs its own batch loader, and every
  paginated association needs a separate count, page and cursor logic.
- **the same decisions are made again**, slightly differently each time: how pages are
  numbered, what a cursor contains, how validation errors are reported, which filter
  arguments are allowed.

With [graphql-ruby](https://graphql-ruby.org) alone, a list of published posts with their
author and comments, filterable by author, looks roughly like this:

```ruby
class Types::PostType < Types::BaseObject
  field :id, ID, null: false
  field :title, String, null: false
  field :author, Types::UserType, null: false
  field :comments, Types::CommentType.connection_type, null: false

  def author
    dataloader.with(Sources::RecordById, User).load(object.author_id)
  end

  def comments
    object.comments.order(:created_at) # one query per post
  end
end

class Types::QueryType < Types::BaseObject
  field :posts, Types::PostType.connection_type, null: false do
    argument :author_id, ID, required: false
  end

  def posts(author_id: nil)
    scope = Post.published.order(created_at: :desc)
    author_id ? scope.where(author_id: author_id) : scope
  end
end
```

…plus the `Sources::RecordById` batch loader, and more code to batch the comments. With
Lighthouse, it is the schema:

```graphql
type Query {
  posts(authorId: ID @eq): [Post!]! @paginate(type: CONNECTION) @builder(class: "Published")
}

type Post {
  id: ID!
  title: String!
  author: User! @belongsTo
  comments: [Comment!]! @hasMany(type: CONNECTION, scopes: ["chronological"])
}
```

The `author` of every post loads in one query, and so does every post's page of
comments, with one more for their totals if the client asks for `pageInfo { total }`. This isn't a
special case: it is how every relationship directive works.

## Why the schema comes first

In a schema-first API, the `.graphql` files *are* the API's definition, not something
generated from Ruby classes:

- **It is a contract you can read.** Frontend developers, mobile developers and reviewers
  read the same SDL that clients query. A pull request that changes the API shows the
  change in the schema diff.
- **It is designed before it is implemented.** You can agree on the types and fields
  first, as a team, and the server follows the design rather than leaking its internals.
- **Tools understand it directly.** IDE plugins, code generators and schema registries
  read SDL. Lighthouse's `lighthouse:ide_helper` task adds its directives and generated
  types so editors validate and autocomplete the schema.
- **It says what each field does.** `posts: [Post!]! @paginate @guard @cacheControl(maxAge: 60)`
  tells a reader, without opening any Ruby, that the field is paginated, requires a
  signed-in user and can be cached for a minute.

## Why directives

Directives are a small vocabulary that composes. Each one does one job, and a field
combines them:

```graphql
type Mutation {
  updatePost(input: UpdatePostInput! @spread): Post!
    @guard                                        # require a user
    @canFind(ability: "update", find: "input.id") # PostPolicy#update?
    @update                                       # save through Active Record, in a transaction
    @clearCache(type: "Post", idSource: { argument: "input.id" })
}
```

Because the behaviour is declared, Lighthouse controls the order it runs in
(authentication, then authorization, then validation, then the save, then cache
invalidation) and handles the details the same way everywhere: pagination types and
cursors, validation errors keyed by argument path, `Cache-Control` headers. That
consistency is what a hand-written resolver per field rarely achieves.

## Why it fits Active Record

A directive can only be this short if something else knows the details. In Lighthouse,
that is the model layer. Active Record is opinionated, and every convention it imposes is
information Lighthouse can use:

| Active Record already knows | So Lighthouse can |
| --- | --- |
| Associations, their foreign keys, `:through` and polymorphic links | Resolve `@hasMany`, `@belongsTo`, `@belongsToMany` and `@morph*` from the name alone, batch them, and paginate many parents in one query |
| Scopes | Narrow any query with `scopes: ["published"]` |
| Validations | Report a failed `@create` or `@update` by argument path, with the model's own messages and locale |
| Transactions and callbacks | Run nested mutations (create a post, attach tags, add comments) atomically, with your callbacks |
| Naming conventions (`Post`, `posts`, `author_id`) | Map `Post` to its model, `authorId` to `author_id`, and a field to its association, with no configuration |

The schema says **what** the API offers; the models already say **how** the data
behaves. Nothing is described twice, and your domain logic stays where Rails puts it,
in models, scopes, validations and policies, instead of moving into GraphQL resolvers.
That is the same reason Lighthouse works so well on Eloquent: both are opinionated
Active Record ORMs, and conventions are what make a declarative layer on top possible.

## Ruby where there is real logic

Schema-first doesn't mean schema-only. When a field does something no directive
describes, write Ruby, using graphql-ruby's own classes:

- A `Query` or `Mutation` field without a resolving directive resolves by convention to
  `Queries::FieldName` (a `GraphQL::Schema::Resolver`) or `Mutations::FieldName` (a
  `GraphQL::Schema::Mutation`). See [Queries, Mutations and Builders](resolvers.md).
- `@builder` classes adjust a query; `@validator` contracts check arguments.
- Your own directives plug in through the registry, with the same contracts as the
  built-in ones. See [Custom Directives](custom-directives.md).

Lighthouse is built on graphql-ruby, not instead of it: its Dataloader, its execution
engine and its classes are all there when you need them.

## From small apps to large ones

The same schema serves a side project and a busy API. When it grows, opt-in features keep
it fast without changing the schema: a cached schema build for quick boots, Apollo's
persisted queries for CDN caching, and an allowlist of trusted operations. They are all
off by default. See [Performance at scale](performance.md).

## When something else fits better

Lighthouse is at its best when the API is close to your models. Consider plain
graphql-ruby, or using Lighthouse only for part of the schema, when:

- the API is mostly computed, aggregated or fetched from other services, rather than read
  from and written to your database;
- your team prefers to define the schema in Ruby and generate the SDL from it
  (code-first);
- types differ so much from your tables that most fields would need their own resolver.

Both approaches run on graphql-ruby, and a Lighthouse schema can call graphql-ruby
classes anywhere, so you can start with directives and write Ruby where it pays off.

Ready to try it? Continue with [Getting Started](getting-started.md).
