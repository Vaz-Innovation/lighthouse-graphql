# Relationships

Just like in Rails, you can resolve associations directly from your schema. Add a
field named after the association and annotate it with the matching directive.

```ruby
class Post < ApplicationRecord
  belongs_to :author, class_name: 'User'
  has_many :comments
end
```

```graphql
type Post {
  author: User! @belongsTo(relation: "author")
  comments: [Comment!]! @hasMany
}
```

## Avoiding the N+1 problem

Resolving relationships naively triggers one query per parent record. Lighthouse's
relationship directives load through graphql-ruby's **Dataloader**, batching all
sibling loads into a single query. Enable it on your schema:

```ruby
class AppSchema < BaseAppSchema
  use GraphQL::Dataloader
end
```

With the Dataloader in place, a query for 100 posts and their authors issues two
queries, not 101.

## One-to-many — `@hasMany`

```graphql
type User {
  posts: [Post!]! @hasMany
}
```

`@hasMany` returns a **connection** type, so it supports pagination arguments and
`edges { node { ... } }` / `nodes { ... }` selections out of the box. The inverse
is `@belongsTo`.

## One-to-one — `@hasOne`

```graphql
type User {
  profile: Profile @hasOne
}
```

## Inverse — `@belongsTo`

```graphql
type Post {
  author: User! @belongsTo(relation: "author")
}
```

## Many-to-many — `@belongsToMany`

```graphql
type User {
  roles: [Role!]! @belongsToMany
}
```

## Renaming relations

By default the relation name equals the field name (snake_cased). When they
differ, pass `relation:`:

```graphql
type Post {
  writtenBy: User! @belongsTo(relation: "author")
}
```

## Filtering a relationship

Relationship fields accept the same [argument filters](filtering-and-ordering.md)
and [`@whereConditions`](filtering-and-ordering.md#complex-where-conditions) as
root queries, so you can scope the related records:

```graphql
type User {
  publishedPosts(
    status: String @eq
    orderBy: [OrderByClause!] @orderBy
  ): [Post!]! @hasMany(relation: "posts")
}
```
