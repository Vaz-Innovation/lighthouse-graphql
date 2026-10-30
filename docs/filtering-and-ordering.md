# Filtering & Ordering

Lighthouse offers two complementary ways to constrain a query: **simple argument
filters** (one directive per argument) and **complex where conditions** (a single
structured argument the client drives dynamically). Both work on any field backed
by a query — `@all`, `@paginate`, `@first`, `@count`, and the relationship
directives.

## Simple argument filters

Attach a filter directive to a field argument. When the client passes that
argument, Lighthouse folds the corresponding clause onto the query builder.
Filters compose in the order the arguments appear in the SDL.

```graphql
type Query {
  users(
    status: String @eq
    role: [String!] @in
    nameSearch: String @like
    minAge: Int @where(operator: "GTE", key: "age")
  ): [User!]! @all
}
```

| Directive | SQL |
| --- | --- |
| `@eq` | `column = value` |
| `@neq` | `column != value` |
| `@in` | `column IN (...)` |
| `@notIn` | `column NOT IN (...)` |
| `@like` | `column LIKE '%value%'` |
| `@where(operator:)` | operator-driven (see below) |

By default the column is the **snake_cased argument name** (`minAge` → `min_age`).
Override it with `key:` — above, `minAge` filters the `age` column.

### `@where` operators

`@where(operator: "...")` takes these operators:

`EQ`, `NEQ`, `GT`, `GTE`, `LT`, `LTE`, `IN`, `NIN`, `CONTAINS`, `STARTS_WITH`,
`ENDS_WITH`, `IS_NULL`, `IS_NOT_NULL`.

They are not `@whereConditions`' `SQLOperator` values, which follow PHP
Lighthouse (see below).

```graphql
type Query {
  events(
    after: String @where(operator: "GTE", key: "starts_at")
    titleContains: String @where(operator: "CONTAINS", key: "title")
  ): [Event!]! @all
}
```

### Filters inside input objects

Filter directives also go on the fields of an input object. Its fields' filters
apply when the client sends it, at any depth, as in PHP Lighthouse:

```graphql
input PostFilter {
  title: String @like
  author: AuthorFilter
}

input AuthorFilter { id: ID @eq(key: "author_id") }

type Query {
  posts(filter: PostFilter): [Post!]! @all
}
```

`posts(filter: { author: { id: 1 } })` keeps the posts of author 1. In a list of
inputs (`filters: [PostFilter!]`), every input's filters apply, together. An
argument with `@spread` filters the same way.

### One filter of several: `@oneOf`

An input object marked [`@oneOf`](https://spec.graphql.org/draft/#sec-OneOf-Input-Objects)
takes exactly one of its fields: to find a user by id **or** by email, but not
both. Its fields' filters apply to the query:

```graphql
input UserBy @oneOf {
  id: ID @eq
  email: String @eq
}

type Query {
  user(by: UserBy!): User @find
}
```

```graphql
{ user(by: { email: "ada@example.com" }) { id } }
```

graphql-ruby validates it: a query giving two fields, none, or a `null` is rejected
before anything resolves, and introspection reports the type's `isOneOf`. Every
field of a `@oneOf` input is nullable and has no default value; the schema fails to
build otherwise.

`@oneOf` is built in, so the SDL needn't declare it. A `directive @oneOf on
INPUT_OBJECT` copied from elsewhere is ignored, like a definition of `@skip`,
`@include`, `@deprecated` or `@specifiedBy`: graphql-ruby's own directive stays.

## Ordering

`@orderBy` works as in PHP Lighthouse. On an argument, the client picks the
order. On a field, the order is fixed.

### Client-controlled ordering

Write the argument's type as `_`. Lighthouse then generates an input that
takes the allowed columns as an enum, together with the `SortOrder` enum:

```graphql
type Query {
  posts(orderBy: _ @orderBy(columns: ["posted_at", "title"])): [Post!]! @all
}
```

Lighthouse generates this from it:

```graphql
"Order by clause for Query.posts.orderBy."
input QueryPostsOrderByOrderByClause {
  "The column that is used for ordering."
  column: QueryPostsOrderByColumn!

  "The direction that is used for ordering."
  order: SortOrder!
}

"Allowed column names for Query.posts.orderBy."
enum QueryPostsOrderByColumn {
  POSTED_AT @enum(value: "posted_at")
  TITLE @enum(value: "title")
}

"Directions for ordering a list of records."
enum SortOrder {
  ASC
  DESC
}
```

The argument becomes `orderBy: [QueryPostsOrderByOrderByClause!]`. The client
passes a list of clauses, which apply in turn:

```graphql
{
  posts(orderBy: [{ column: POSTED_AT, order: DESC }, { column: TITLE, order: ASC }]) {
    title
  }
}
```

The names follow `<Type><Field><Argument>`: `QueryPostsOrderBy…` for
`Query.posts(orderBy:)`. Each clause needs an `order`. Without `columns:`,
`columnsEnum:` or `relations:`, the argument takes the shared `OrderByClause`,
whose `column` is a `String!`. That allows any column, so restrict the columns
whenever clients are not trusted.

To reuse one enum on several fields, name it with `columnsEnum:`. Its
`@enum(value:)` gives each value's column:

```graphql
type Query {
  allPosts(orderBy: _ @orderBy(columnsEnum: "PostColumn")): [Post!]! @all
  paginatedPosts(orderBy: _ @orderBy(columnsEnum: "PostColumn")): [Post!]! @paginate
}

enum PostColumn {
  POSTED_AT @enum(value: "posted_at")
  TITLE @enum(value: "title")
}
```

`columns:` and `columnsEnum:` cannot be used together.

### Ordering by a relation

`relations:` lets the client order by an aggregate of a relation. Without
columns, that aggregate is `COUNT`. With a relation's own `columns:` (or
`columnsEnum:`), it is `AVG`, `MIN`, `MAX`, `SUM` or `COUNT` of one of them:

```graphql
type Query {
  users(
    orderBy: _ @orderBy(columns: ["name"], relations: [{ relation: "posts" }, { relation: "tasks", columns: ["difficulty"] }])
  ): [User!]! @all
}
```

```graphql
{
  users(
    orderBy: [
      { posts: { aggregate: COUNT }, order: DESC }
      { tasks: { aggregate: MAX, column: DIFFICULTY }, order: DESC }
      { column: NAME, order: ASC }
    ]
  ) {
    name
  }
}
```

The argument then takes `[QueryUsersOrderByRelationOrderByClause!]`. Each clause
names exactly one of `column` and the relations. Each relation has an input of
its own, `QueryUsersOrderByPosts` / `QueryUsersOrderByTasks`, with the
`OrderByRelationAggregateFunction` or
`OrderByRelationWithColumnAggregateFunction` enum.

The aggregate is computed once per record, in a `LEFT JOIN` on a grouped
subquery. A record with no related records is still listed, with a `COUNT` of 0.
This also works on a relationship field (`posts(orderBy: _ @orderBy(...)): [Post!]! @hasMany`),
including when its pages are batched.

### Predefined ordering

On a field, `@orderBy(column:, direction:)` always orders the result, whatever
the client sends:

```graphql
type Query {
  latestUsers: [User!]! @all @orderBy(column: "created_at", direction: DESC)
}
```

A field's `@orderBy` applies after the client's `orderBy` argument, so on a
field with both, it breaks ties:

```graphql
type Query {
  posts(orderBy: _ @orderBy(columns: ["title"])): [Post!]! @paginate @orderBy(column: "created_at", direction: DESC)
}
```

An argument written with a type of its own, such as `orderBy: [MyClause!] @orderBy`,
keeps that type. Its input needs a `column` and an `order`.

## Full-text search

`@search` runs a field's query through a full-text engine when the client sends a
search term, as PHP Lighthouse's does through Laravel Scout (the directive is in
[directives.md](directives.md#search)). Lighthouse supports the two gems Rails apps
use, behind one adapter seam; neither is a dependency of Lighthouse, so add the one you use
to your Gemfile.

```graphql
type Query {
  posts(
    search: String @search
    authorId: ID @eq(key: "author_id")
    orderBy: _ @orderBy(columns: ["created_at"])
  ): [Post!]! @paginate
}
```

The search runs when the client sends a string for the argument (`""` too). `null` or
nothing leaves the query to the database.

### With pg_search (in the database)

```ruby
class Post < ApplicationRecord
  include PgSearch::Model
  pg_search_scope :search, against: { title: 'A', body: 'B' }
  pg_search_scope :search_title, against: :title
end
```

`@search` calls the scope `search` (or the one `within:` names: `@search(within: "search_title")`)
on the field's relation. Because a pg_search scope is a relation, **everything else Lighthouse does
composes on it**: the field's `scopes:`, `@builder`, `@whereAuth`, every argument filter,
`@whereConditions`, `@orderBy`, nested fields and nested `@paginate` (batched through one window
query), `@count`, `@first` and `@find`.

**Order.** pg_search's rank sorts first, then the client's `orderBy`, the field's
`@orderBy(column:)` and the primary key break its ties. A search is ordered by relevance, so a client
that sorts by date gets the best matches first and, among equally ranked ones, the newest. A
`scopes:` entry that orders the relation sorts before the rank, since it is applied first.

### With Searchkick (outside the database)

```ruby
class Post < ApplicationRecord
  searchkick

  def search_data = { title: title, body: body, author_id: author_id, deleted_at: deleted_at }
end
```

Searchkick queries Elasticsearch / OpenSearch, which knows nothing of your database, so what
narrows a search must be translated into the engine's filters. Lighthouse does it for the
directives of PHP Lighthouse's `ScoutBuilderDirective`:

| Directive | In the search |
| --- | --- |
| `@eq` | `where: { column => value }`, so the column must be in `search_data` |
| `@trashed` | filters on the soft-delete column the index holds: `ONLY` keeps the records with a value in it, `WITHOUT` those without, `WITH` both, if you index trashed records. The column is paranoia's or discard's, else `deleted_at`; `Config.search = Lighthouse::Search::Searchkick.new(trashed_column: :archived_at)` names another. A model whose `search_data` does not hold it is an error. Apps often leave trashed records out of the index (`should_index?`): then `ONLY` finds nothing. |
| `@builder` on an argument | gets the `Lighthouse::Search::Query` instead of the relation (below) |

The directives work at any depth of input objects (`filter: PostFilter` with `@eq` fields). The
engine answers with Active Record records, loaded in one query and in relevance order, so
nested fields and the Dataloader work on them as usual.

```ruby
# app/graphql/builders/title_fields.rb: `titleOnly: Boolean @builder(class: "TitleFields")`
class Builders::TitleFields
  def self.call(target, value, _context)
    return target unless value
    return target.where(body: nil) unless target.is_a?(Lighthouse::Search::Query)  # a relation

    target.options[:fields] = ['title^10']  # passed to Searchkick's search
    target
  end
end
```

A query holds `model`, `term`, `index`, `wheres`, `trashed` and `options` (Searchkick's `fields:`,
`match:`, `boost_by:`, ... as a hash).

**Which fields.** The engine answers with records, not a relation, so `@search` with Searchkick
is for `@all` and `@paginate` on a root field (or with `model:`). Any other field (`@find`,
`@first`, `@count`, a nested relationship, a field resolved by your own class) is a schema error at
build. For the same reason a field with `scopes:`, `@builder`, `@whereAuth` or `@orderBy(column:)`
is a schema error: **PHP Lighthouse drops those silently when it searches**, and a search that skipped
`@whereAuth` would return records the user must not see. Lighthouse fails when the schema is built
instead. Put the constraint in the index (`search_data` and a `@eq` argument), or search with pg_search.

At run time, a client that sends an argument whose directive the engine cannot apply (`@neq`,
`@in`, `@like`, `@orderBy`, `@whereConditions`, ...) with a search, or two `@search`
arguments, gets an error, as in PHP Lighthouse. (`@in`, `@notIn` and `@whereKey`, which Scout
has as `whereIn` / `whereNotIn`, are not supported yet.)

### Pagination

`@paginate` pages a search with all three types: `PAGINATOR`, `SIMPLE` and `CONNECTION`, whose
cursors are positions that Searchkick's `offset:` covers. The engine's response holds the total, so
a page and `paginatorInfo { total }` cost **one request**. Unlike Scout, `first: 0` can still count.
`@all` reads the records through `first` and `offset` when the field has them, else up to 10,000
(Elasticsearch's default `index.max_result_window`).

### Choosing the engine

By default the engine is detected per model: Searchkick if it calls `searchkick`, else pg_search if
it includes `PgSearch::Model`. [`Config.search`](configuration.md#search) replaces that with one
adapter (`Lighthouse::Search::PgSearch.new`, `Lighthouse::Search::Searchkick.new`) or your own. An
adapter answers `searchable?(model, index)`, `relational?` and either `scope(relation, query)` (a
relational one, like pg_search) or `page(query, offset:, limit:)` returning `[records, total]`. This
protocol is experimental.

### Errors

| Case | PHP Lighthouse | Lighthouse |
| --- | --- | --- |
| Two `@search` arguments sent | `ScoutException` at run time | client error |
| An argument the engine cannot apply is sent | `ScoutException` at run time | same with Searchkick; none with pg_search |
| Model not searchable | `ScoutException` at run time | schema error at build, once the field's model is known |
| `within:` not a string | `DefinitionException` | schema error at build |
| Nested field (a relation) | `ScoutException` at run time | schema error with Searchkick; works with pg_search |
| Field has `scopes:`, `@builder`, `@whereAuth`, `@orderBy(column:)` | dropped silently | schema error with Searchkick; applied with pg_search |

## Complex where conditions

`@whereConditions` works as in PHP Lighthouse. The client builds the `WHERE`
clause itself, from conditions joined by `AND` and `OR`, and from `HAS` checks on
relations. Write the argument's type as `_`, and declare the allowed columns:

```graphql
type Query {
  people(
    where: _ @whereConditions(columns: ["age", "type", "haircolour", "height"])
  ): [Person!]! @all
}
```

Lighthouse generates these types for `Query.people(where:)`:

```graphql
"Dynamic WHERE conditions for the `where` argument of Query.people."
input QueryPeopleWhereWhereConditions {
  column: QueryPeopleWhereColumn
  operator: SQLOperator = EQ
  value: Mixed
  AND: [QueryPeopleWhereWhereConditions!]
  OR: [QueryPeopleWhereWhereConditions!]
  HAS: QueryPeopleWhereWhereConditionsRelation
}

"Allowed column names for Query.people.where."
enum QueryPeopleWhereColumn {
  AGE @enum(value: "age")
  TYPE @enum(value: "type")
  HAIRCOLOUR @enum(value: "haircolour")
  HEIGHT @enum(value: "height")
}

input QueryPeopleWhereWhereConditionsRelation {
  relation: String!
  operator: SQLOperator = GTE
  amount: Int = 1
  condition: QueryPeopleWhereWhereConditionsHasCondition
}
```

`QueryPeopleWhereWhereConditionsHasCondition` has the same fields as the
conditions input, but its `column` is a `String`. It filters the related
records, whose columns are not the model's.

The conditions of one level all hold. An `AND` list is a group whose conditions
all hold, and an `OR` list is a group where at least one does:

```graphql
{
  people(
    where: {
      AND: [
        { column: AGE, operator: GT, value: 37 }
        { column: TYPE, value: "Actor" }
        {
          OR: [
            { column: HAIRCOLOUR, value: "red" }
            { column: HEIGHT, operator: GTE, value: 150 }
          ]
        }
      ]
    }
  ) {
    name
  }
}
```

```graphql
{
  people(
    where: {
      AND: [
        { column: HAIRCOLOUR, operator: IS_NULL }
        { column: HEIGHT, operator: BETWEEN, value: [150, 200] }
      ]
    }
  ) {
    name
  }
}
```

`where: null` filters nothing.

### Operators

The generated `SQLOperator` enum has PHP Lighthouse's operators. `IS_NULL` and
`IS_NOT_NULL` take no value. Any other operator needs one, or the query fails
with "Did not receive a value to match the WhereConditions for column …".

| Operator | SQL | `value` |
| --- | --- | --- |
| `EQ` (default) | `=` | a scalar |
| `NEQ` | `!=` | a scalar |
| `GT`, `GTE`, `LT`, `LTE` | `>`, `>=`, `<`, `<=` | a scalar |
| `LIKE`, `NOT_LIKE` | `LIKE`, `NOT LIKE` | a pattern: `"%Rails%"` |
| `IN`, `NOT_IN` | `IN`, `NOT IN` | a list |
| `BETWEEN`, `NOT_BETWEEN` | `BETWEEN`, `NOT BETWEEN` | `[from, to]` |
| `IS_NULL`, `IS_NOT_NULL` | `IS NULL`, `IS NOT NULL` | none |

### Related records — `HAS`

`HAS` keeps the records that have related records. By default, at least one,
which is `operator: GTE, amount: 1`. Its `condition` filters the related
records, on their own table's columns:

```graphql
{
  users(where: { HAS: { relation: "posts", amount: 3, condition: { column: "published", value: true } } }) {
    name
  }
}
```

`relation` names an association of the model (`posts`, or `blogPosts` for
`blog_posts`). `{ relation: "posts", operator: LT, amount: 1 }` keeps the users
with no posts. A `condition` can hold its own `HAS`, which checks the related
records' relations.

### Without `columns:`

Without `columns:` or `columnsEnum:`, the argument takes the shared
`WhereConditions` input, whose `column` is a `String`. A column a client
names there must be an identifier or `table.column`, optionally followed by a
[JSON path](#json-columns) (`meta->tags`). Anything else fails with "Column names
may contain only alphanumerics or underscores, optionally a table and a JSON path
(posts.meta->tags), and may not begin with a digit, got: …". Any column of the
table can still be filtered on, so declare the allowed columns when clients are
not trusted.

### JSON columns

As in PHP Lighthouse (and Laravel), a column can point into a JSON document with
`->`: `meta->series`, `meta->author->name`, and `meta->tags->0` for an array
element. `@whereConditions`, `@whereHasConditions` and `@orderBy`, on an argument
or on a field, take it in `columns:` like any column:

```graphql
type Query {
  posts(
    where: _ @whereConditions(columns: ["title", "meta->series", "meta->rank"])
    orderBy: _ @orderBy(columns: ["meta->rank"])
  ): [Post!]! @all
  rankedPosts: [Post!]! @all @orderBy(column: "meta->rank", direction: DESC)
}
```

The generated enum names the path with `__` (`META__SERIES`, `META__AUTHOR__NAME`):

```graphql
{
  posts(
    where: { AND: [{ column: META__SERIES, value: "graphql" }, { column: META__RANK, operator: GT, value: 9 }] }
    orderBy: [{ column: META__RANK, order: DESC }]
  ) {
    title
  }
}
```

The value at the path is compiled for the database: `"meta"->>'series'` on
PostgreSQL, `JSON_UNQUOTE(JSON_EXTRACT(meta, '$."series"'))` on MySQL, and
`json_extract(meta, '$."series"')` on SQLite. Unlike Laravel, it behaves the same
on all three:

- A number compares as a number (`meta->rank GT 9` keeps 10), and a boolean as a
  boolean. `LIKE` compares the text.
- `IS_NULL` holds for a missing key and for a JSON `null`.
- `@orderBy` orders by the JSON value, so numbers sort numerically.

### A custom handler

`handler:` names a class, looked up in `Config.namespaces[:builders]` (`Builders::`).
It applies the conditions instead of Lighthouse:

```graphql
type Query {
  people(where: _ @whereConditions(columns: ["age"], handler: "PeopleConditions")): [Person!]! @all
}
```

```ruby
class Builders::PeopleConditions
  # `conditions` as the client sent them: { column: "age", operator: "GT", value: 37, and: [...], ... }
  def self.call(relation, conditions)
    relation.where(...)
  end
end
```

Use `"Class@method"` to call another method.

## `@whereHasConditions`

`@whereHasConditions` keeps the records that have at least one related record
matching the client's conditions. The input is the same as `@whereConditions`',
applied to the relation:

```graphql
type Query {
  people(hasRole: _ @whereHasConditions(columns: ["name", "access_level"])): [Person!]! @all
}
```

```graphql
{
  people(hasRole: { column: ACCESS_LEVEL, operator: GTE, value: 5 }) {
    name
  }
}
```

The relation is the argument's name without `has` (`hasRole` → `role`, and
`roles` if the model has that instead). You can also name it with `relation:`:
`work: _ @whereHasConditions(relation: "tasks")`. The generated input is
`QueryPeopleHasRoleWhereHasConditions`.

`hasRole: {}` keeps the people with any role. `hasRole: null` filters nothing.

The client's conditions are an argument directive like any other, so they also
work on `@paginate`, `@count`, `@first`, the relationship directives, and
`resolve_info.enhance_builder`. The argument can have any name.

## How columns are resolved

Column names from enums (e.g. `CREATED_AT`) and arguments (`minAge`) are mapped to
real columns through one central rule (`Lighthouse::Support::Naming`): ALLCAPS
enum keys are downcased, and camelCase is converted to snake_case. This keeps
client-facing GraphQL idiomatic while matching your Rails schema. An enum
value's `@enum(value:)` names its column directly, as in the enums `@orderBy`
and `@whereConditions` generate.
