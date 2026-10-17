---
home: true
title: SDL-first GraphQL for Rails
heroImage: /logo.svg
heroText: Lighthouse GraphQL Rails
tagline: A framework for serving GraphQL from Ruby on Rails
actions:
  - text: Get Started →
    link: /docs/getting-started.md
    type: primary
  - text: Directives
    link: /docs/directives.md
    type: secondary
features:
  - title: 📜 SDL First
    details: Describe your API in the GraphQL Schema Definition Language and add behaviour with server-side directives, instead of a resolver class for every field.
  - title: 🛤️ Rails Friendly
    details: Built on graphql-ruby for an existing Rails app. Your models, scopes, validations, Pundit policies and Rails.cache keep doing their jobs.
  - title: ⚡ Optimized for Active Record
    details: Relationships and pages load in batches through the Dataloader, so a list of 100 posts with their authors and comments is a handful of queries.
editLink: false
footer: MIT Licensed · A Ruby on Rails port of nuwave/lighthouse (Laravel)
---

### Boilerplate-free schema definition

Define your schema without any boilerplate, using the GraphQL Schema Definition Language.

```graphql
type User {
  name: String!
  posts: [Post!]! @hasMany(type: PAGINATOR)
}

type Post {
  title: String!
  author: User! @belongsTo
}

type Query {
  me: User @guard
  posts(orderBy: [PostOrderByClause!] @orderBy): [Post!]! @paginate(defaultCount: 10)
}

type Mutation {
  createPost(input: CreatePostInput! @spread): Post!
    @guard
    @canModel(ability: "create")
    @create
    @inject(context: "current_user.id", name: "author_id")
}
```

### Get going in minutes

Add the gem, run the installer, and query the schema it generates.

```shell
bundle add lighthouse-graphql
bin/rails generate lighthouse:install
```

```shell
curl localhost:3000/graphql -H 'Content-Type: application/json' \
  -d '{"query": "{ users { data { id name } paginatorInfo { total } } }"}'
```

### Ruby where there is real logic

A `Query` or `Mutation` field without a resolving directive resolves by convention to a
graphql-ruby class: `Mutation.publishPost` to `Mutations::PublishPost`.

```ruby
class Mutations::PublishPost < GraphQL::Schema::Mutation
  def resolve(id:)
    Post.find(id).tap { |post| post.update!(published: true) }
  end
end
```

### Built for small apps and large ones

Nested mutations, `@whereConditions`, model validations and Dry::Validation contracts,
the `@can*` family over Pundit, `@cache` and `@cacheControl`, Apollo Federation — and,
when you need them, a schema cache, persisted queries and an operation allowlist.
