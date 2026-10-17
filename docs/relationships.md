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
  author: User! @belongsTo
  comments: [Comment!]! @hasMany
}
```

| Directive | ActiveRecord association |
| --- | --- |
| `@belongsTo` | `belongs_to` |
| `@hasOne` | `has_one` |
| `@hasMany` | `has_many` |
| `@belongsToMany` | `has_many :through`, `has_and_belongs_to_many` |
| `@morphTo` | `belongs_to …, polymorphic: true` |
| `@morphOne` / `@morphMany` | `has_one` / `has_many …, as:` |
| `@morphToMany` | `has_many :through` a polymorphic join |

The `morph*` names are PHP Lighthouse's. ActiveRecord resolves polymorphic
associations the same way as any other, so they behave exactly like their
non-polymorphic counterparts. Use whichever reads better.

## Avoiding the N+1 problem

The relationship directives load through graphql-ruby's **Dataloader** and
ActiveRecord's preloader, one query per association per batch. Enable the
Dataloader on your schema (the install generator does):

```ruby
AppSchema = Lighthouse::GraphQL::RbLightHouse.get_schema(
  options: { using: { GraphQL::Dataloader => {} } }
)
```

A query for 100 posts and their authors then issues two queries, not 101. A
many-to-many or `:through` association adds one query for the join table. Without
the Dataloader, the directives still work, but they load one parent at a time.

A field with `scopes:` or a filter argument the client supplied runs its own query
per parent, because each parent's query differs.

## Lists, and paginating them

Collection directives return a **plain list**, as in PHP Lighthouse:

```graphql
type User {
  posts: [Post!]! @hasMany
}
```

```graphql
{ user(id: 1) { posts { title } } }
```

To paginate, pass `type:`, which takes the same values as
[`@paginate`](directives.md#paginate): `PAGINATOR`, `SIMPLE` or `CONNECTION`.
Lighthouse rewrites the field and adds the pagination arguments:

```graphql
type User {
  posts: [Post!]! @hasMany(type: PAGINATOR, defaultCount: 10)
  feed: [Post!]! @hasMany(relation: "posts", type: CONNECTION)
}
```

```graphql
{
  user(id: 1) {
    posts(first: 5, page: 2) { paginatorInfo { total lastPage } data { title } }
    feed(first: 5, after: "NQ==") { pageInfo { hasNextPage endCursor } edges { node { title } } }
  }
}
```

`defaultCount` and `maxCount` work as on `@paginate`.

## Renaming relations

By default the relation name is the field name, snake_cased. When they differ,
pass `relation:`:

```graphql
type Post {
  writtenBy: User! @belongsTo(relation: "author")
}
```

## Scopes and filters

`scopes:` applies model scopes to the association. Relationship fields also
accept the same [argument filters](filtering-and-ordering.md) and
[`@whereConditions`](filtering-and-ordering.md#complex-where-conditions) as root
queries:

```graphql
type User {
  publishedPosts(
    title: String @like
    orderBy: [OrderByClause!] @orderBy
  ): [Post!]! @hasMany(relation: "posts", scopes: ["published"])
}
```

## Writing relationships

Creating, connecting, syncing or deleting related records from a mutation's input
is covered by [nested mutations](mutations.md#nested-mutations).
