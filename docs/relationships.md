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

`@hasMany` and `@hasOne` resolve `has_many` / `has_one :through` associations as
they are. PHP Lighthouse's `@hasManyThrough` and `@hasOneThrough` work too, as
aliases, so an SDL written for it builds unchanged.

## Avoiding the N+1 problem

The relationship directives load through graphql-ruby's **Dataloader** and
ActiveRecord's preloader, one query per association per batch. Enable the
Dataloader on your schema (graphql-ruby's install does, and with `--batch`
`lighthouse:install` adds it beside GraphQL::Batch):

```ruby
class AppSchema < Lighthouse::GraphQL::RbLightHouse.get_schema(options: { base_types: { object: Types::BaseObject } })
  use GraphQL::Dataloader
end
```

A query for 100 posts and their authors then issues two queries, not 101. A
many-to-many or `:through` association adds one query for the join table. Without
the Dataloader, the directives still work, but they load one parent at a time.

A field with `scopes:` or a filter argument the client supplied runs its own query
per parent, because each parent's query differs.

## Eager loading for other fields

The relationship directives load their own association. Three directives load for
the fields that only read one: a method, a type class method, a field read off
the model. Each one loads across every parent in the response at once, through the
Dataloader:

- `@with(relation: "tasks")` loads a relation of the parent before the field
  resolves. `user.tasks` is then in memory for the method that reads it.
- `@withCount(relation: "posts")` counts a relation for every parent in one
  `GROUP BY` query, and keeps each count on its parent as `<relation>_count`, as
  Laravel's `withCount` does. It is not the field's value: the field's resolver,
  or the default reader of a `postsCount` field, reads `user.posts_count`.
- `@lazyLoad(relations: ["tags"])` loads relations of the records the field
  returns: a list, a relation, a `@paginate` page. On a `@hasMany`, the records of
  every parent load their relations together.

```graphql
type User {
  latestPostTitle: String @with(relation: "posts") @method
  usage: String! @withCount(relation: "posts", scopes: ["published"]) @method
  posts: [Post!]! @hasMany @lazyLoad(relations: ["tags"])
}
```

```ruby
class User < ApplicationRecord
  def latest_post_title = posts.max_by(&:created_at)&.title
  def usage = "#{posts_count} published posts"
end
```

Relations may be nested with dots (`"posts.comments"`), and `scopes` narrow what is
loaded or counted, as model scopes. A count loads in one query when the database has
window functions and the relation links its parent through one column, as a
[paginated relation](#paginating-many-parents-at-once) does; otherwise once per
parent.

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

### Paginating many parents at once

With the Dataloader, a paginated relation loads the pages of **every parent** of
a level together, as PHP Lighthouse does: `{ users { posts(first: 5) { … } } }`
costs one query for the pages, plus one for the totals if the client selects
`paginatorInfo` or `pageInfo` — however many users there are. The same goes for
`@paginate` on a nested field.

- **Pages.** A window function numbers each parent's rows in the field's order
  (`@orderBy`, else the primary key), and one query keeps the rows of the
  requested page: `ROW_NUMBER() OVER (PARTITION BY posts.user_id ORDER BY …)`.
  PHP Lighthouse uses a `UNION ALL` of one query per parent instead; a window
  function keeps the SQL the same size for 3 parents or 3,000.
- **Totals.** One `GROUP BY` counts every parent's related records, with the same
  scopes and filters as the page. The count only runs when a total is asked for,
  and never for `SIMPLE`, which fetches one extra row instead.

This needs window functions: PostgreSQL, MySQL 8+, MariaDB 10.2+ or SQLite 3.25+.
A relation falls back to one query per parent on other databases, without the
Dataloader, and when its rows can't be numbered per parent: a composite key, an
association scope that reads the owner (`has_many :x, ->(owner) { … }`), or
`DISTINCT`. The pages are the same either way.

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
