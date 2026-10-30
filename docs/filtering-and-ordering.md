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
[directives.md](directives.md#search)). Ruby has no Scout: Lighthouse supports the two gems
Rails apps use, behind one adapter seam. Neither is a dependency of Lighthouse, so add the
one you use to your Gemfile.

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

| | [pg_search](https://github.com/Casecommons/pg_search) | [Searchkick](https://github.com/ankane/searchkick) |
| --- | --- | --- |
| Searches | PostgreSQL's full-text search, in the table | an Elasticsearch or OpenSearch index, a copy of the table |
| The search is | a scope on the field's relation | an engine request that answers records |
| Everything else Lighthouse applies | composes on it | only `@eq`, `@trashed` and `@builder` on an argument |
| Fields | any | `@all`, `@paginate` on a root field, a resolver of your own |
| Up to date | always | once the index is (callbacks, jobs) |

Lighthouse is tested with Searchkick 6.2 on Elasticsearch 9.5 and on OpenSearch 2.19 and 3.9,
and with pg_search 2.3 and 2.4 on PostgreSQL 16 (the [example app](https://github.com/Vaz-Innovation/lighthouse-graphql/tree/main/example)'s suite).

### Setting up pg_search

```ruby
# Gemfile
gem 'pg_search'
```

```ruby
class Post < ApplicationRecord
  include PgSearch::Model

  pg_search_scope :search, against: { title: 'A', body: 'B' }, using: { tsearch: { prefix: true } }
  pg_search_scope :search_title, against: :title
end
```

`@search` calls the scope `search`, or the one `within:` names: `@search(within: "search_title")`.
There is nothing to index: the scope searches the table, so a search sees every change at once.
On a model that uses both gems, a `within:` that names one of its pg_search scopes searches with
pg_search; no `within:`, or any other, searches with Searchkick (where it names an index).

### Setting up Searchkick

```ruby
# Gemfile
gem 'searchkick'
gem 'elasticsearch'      # Elasticsearch: the client's major version is the server's (9 for Elasticsearch 9, 8 for 8)
# or
gem 'opensearch-ruby'    # OpenSearch 2 or 3
```

Searchkick talks to `ELASTICSEARCH_URL` or `OPENSEARCH_URL` (`http://localhost:9200` by default).
With both clients loaded (say, Elasticsearch in production and OpenSearch elsewhere), Searchkick
refuses to guess: name the one in use in an initializer, and require only it:

```ruby
# config/initializers/searchkick.rb, with both gems `require: false` in the Gemfile
if ENV['OPENSEARCH_URL']
  require 'opensearch'
  Searchkick.client_type = :opensearch
else
  require 'elasticsearch'
  Searchkick.client_type = :elasticsearch
end
```

Then the model. The index is a copy of what `search_data` says, so it must hold the text to search
**and every column a filter of the field reads**: the `key:` of each `@eq`, and the soft-delete
column for `@trashed`. An `@eq` on a column the index does not hold matches nothing.

```ruby
class Comment < ApplicationRecord
  belongs_to :post

  searchkick callbacks: :async

  # What the index holds: `body` to search, `post_id` for an `@eq(key: "post_id")` argument.
  def search_data = { body: body, post_id: post_id }

  # Which records are indexed at all: what must not be found must not be indexed.
  def should_index? = post.published?

  # What a reindex loads with each batch, for search_data and should_index?.
  scope :search_import, -> { includes(:post) }

  # What a search may return, checked in the database as the records it finds load.
  scope :search_results, -> { where(post: Post.published) }
end
```

```graphql
type Query {
  searchComments(search: String! @search, postId: ID @eq(key: "post_id")): [Comment!]! @paginate
}
```

Run `Comment.reindex` once, to create the index and fill it, and again after you change
`search_data` or the index's settings. Searchkick's callbacks keep it up to date as records change:
in the same request by default, or in an Active Job with `callbacks: :async` (start a worker, such
as `bin/jobs` for Solid Queue). `should_index?` only decides on the record that changed: when another
record decides it (unpublishing a post hides its comments), reindex those too: the example app's
Post calls `comments.reindex(mode: :async)` in an `after_commit` when `published` changes.
`search_import` is Searchkick's: without it, a `should_index?` or `search_data` that reads an
association loads it once per record.

### What Lighthouse does with pg_search

`@search` calls the scope on the field's relation. Because a pg_search scope is a relation,
**everything else Lighthouse does composes on it**: the field's `scopes:`, `@builder`, `@whereAuth`,
every argument filter, `@whereConditions`, `@orderBy`, nested fields and nested `@paginate`
(batched through one window query), `@count`, `@first`, `@find` and `@canQuery`.

A mass mutation (`@delete`, `@forceDelete`, `@restore`) can take a `@search` argument too: it acts on
the records the search finds. It still refuses to run without a filter (`Would modify all models, use
an argument to filter.`), and a `@search` argument counts as one only when the search runs, for a
string: `deletePosts(search: null)` deletes nothing, as in PHP Lighthouse. With Searchkick a mass
mutation is a schema error.

**Order.** A search is in order of relevance: pg_search's rank always sorts first. The orders the
relation already had break its ties, in the order they apply, as on a field without a search: the
model's default scope, the field's `scopes:`, the model's `search_results` scope; then the client's
`orderBy`, the field's `@orderBy(column:)`, and the primary key ends the order, once, unless an order
before already names it. A client that sorts by date gets the best matches first and, among equally
ranked ones, the newest; matches that rank and sort alike come back in the same order every time, on
every field. pg_search's own tie-break, the primary key, is dropped so that these orders decide (a node
of its own in pg_search 2.4, the end of the rank's SQL in 2.3); an `order_within_rank:` the scope names
is kept, right after the rank.

### What Lighthouse does with Searchkick

Searchkick queries Elasticsearch or OpenSearch, which knows nothing of your database, so what narrows a
search is translated into the engine's filters. Lighthouse does it for the directives of PHP
Lighthouse's `ScoutBuilderDirective`:

| Directive | In the search |
| --- | --- |
| `@eq` | `where: { column => value }`, a filter on the indexed column |
| `@trashed` | a filter on the indexed soft-delete column: [below](#soft-deletes-in-a-search) |
| `@builder` on an argument | gets the `Lighthouse::Search::Query` instead of the relation (below) |

They work at any depth of input objects (`filter: CommentFilter` with `@eq` fields). The engine
answers with Active Record records, in relevance order, loaded in one query through the model (and
its default scope), so nested fields and the Dataloader work on them as usual.

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

A query holds `model`, `term`, `index`, `wheres`, `trashed` and `options`: any option of Searchkick's
`search` (`fields:`, `match:`, `boost_by:`, `order:`, `misspellings:`, `body_options:`,
`scope_results:`, ...). Lighthouse adds `where:` (merged into yours), `index_name:` (from `within:`),
`load: true`, `body_options: { track_total_hits: true }` (yours win) and `scope_results:` (yours runs
last).

**Which fields.** The engine answers with records, not a relation, so `@search` with Searchkick is for
`@all`, `@paginate` on a root field or with its own `model:`, and a field your own class resolves, which
reads the search through [`resolve_info.enhance_builder`](#in-a-resolver-of-your-own). Any other field
(`@find`, `@first`, `@count`, a mass mutation, a nested relationship) is a schema error at build, when
Lighthouse can tell the field's model. For the same reason a field with `scopes:`, `@builder`,
`@whereAuth` or `@orderBy(column:)`, or an `@canQuery` with `scopes:`, is a schema error: **PHP
Lighthouse drops those silently when it searches**, and a search that skipped `@whereAuth` would return
records the user must not see. Lighthouse fails when the schema is built instead. Put the constraint in
the index (`search_data` and an `@eq` argument), in the model's [`search_results`
scope](#keeping-private-records-out-of-a-search), or search with pg_search.

At run time, a client that sends an argument whose directive the engine cannot apply (`@neq`, `@in`,
`@like`, `@orderBy`, `@whereConditions`, ...) with a search, or two `@search` arguments, gets an error,
as in PHP Lighthouse. Such an argument with a **default value** would be sent on every search, as
graphql-ruby fills the default in (and PHP Lighthouse fails every search of the field): it is a schema
error. So is an input field that holds a value the client did not send, as graphql-ruby fills it in:
the value an argument's default object gives it, else its own default, inside a default object or an
input object the client must send (`filter: PostFilter!`). An input field's default under a parent the
client may leave out (`filter: PostFilter`) applies only when it sends the parent, and is not refused:
a search with that parent is then the run-time error above.
A default for `@eq`, `@trashed` or `@builder` is fine. (`@in`, `@notIn` and `@whereKey`, which Scout has as `whereIn` / `whereNotIn`, are
not supported yet.)

**Order.** The engine's relevance; ties as the engine breaks them. `@orderBy` is refused with a search;
an `@builder` on an argument can set Searchkick's `order:`.

### Pagination and totals

`@paginate` pages a search with all three types: `PAGINATOR`, `SIMPLE` and `CONNECTION`, whose cursors
are positions. With pg_search it pages the relation, as any other. With Searchkick each page is one
engine request (`offset:` and `limit:`), whose response holds the total too, so a page and
`paginatorInfo { total }` cost **one request**. Unlike Scout, `first: 0` can still count.

**The total is exact.** Elasticsearch and OpenSearch stop counting matches at 10,000 unless asked
(`track_total_hits`), which made `total`, `lastPage` and `hasMorePages` wrong past it. Lighthouse asks
on every search. Counting every match costs the engine more on very large result sets; an `@builder`
on an argument can set `query.options[:body_options] = { track_total_hits: false }` (or a number) for a
search where an estimate will do.

**Reads without `first`.** `@all` without `first` reads 10,000 records at most, in one request,
whatever the result window: give the field `first` and `offset`, or use `@paginate`, to read further.

**The result window.** The engines page through the first 10,000 matches only (the index's
`index.max_result_window`). Lighthouse reads no further: a page that runs past it is cut at its end, and
a page that starts past it is an error the client reads:

> The search reads no further than its first 10000 matches (the index.max_result_window of Comment), so
> offset 10000 is past them. Narrow the search instead.

Lighthouse takes the window from the model: `searchkick max_result_window: 50_000` (or `settings: {
index: { max_result_window: 50_000 } }`, with symbol or string keys, nested or as
`'index.max_result_window'`), a billion with `searchkick deep_paging: true`, else 10,000. An index
`within:` names, other than the model's, has a window the model does not tell, so Lighthouse leaves it
to the engine; a window set on the server alone is enforced by the engine too. Its refusal becomes the
same error, without the number: `The search reads no further than the index.max_result_window of
Comment. Narrow the search instead.` Raising the window lets clients page deeper at the engine's expense; Searchkick
[advises against it](https://github.com/ankane/searchkick#deep-paging).

### Soft deletes in a search

With pg_search, `@trashed` and `@softDeletes` filter the relation, as without a search.

With Searchkick, `@trashed` filters on the soft-delete column the index holds, so `search_data` must hold
it (`deleted_at: deleted_at`), or `ONLY` and `WITHOUT` are an error (`WITH` filters nothing): `Comment.search_data does not index
deleted_at, which @trashed filters the search on.` The column is the one the database path filters on
([`Config.soft_deletes`](configuration.md#soft-deletes)): paranoia's (`paranoia_column`, and its
`sentinel_value` in place of null for the records that are not trashed), discard's (`discard_column`),
a `Column.new(:archived_at)`'s, else `deleted_at`. An adapter of your own tells it with `column(model)`
and `kept_value(model)`. `Config.soft_deletes` is the one place to name it: the support check, the
engine's filter and the records' load all read it, as the database filters do.

| `trashed:` | In the engine | Loads the records |
| --- | --- | --- |
| `ONLY` | a value in the column, other than paranoia's sentinel | past the default scope that hides trashed records |
| `WITH` | no filter | past that default scope |
| `WITHOUT` | no value in the column, or the sentinel | through the model, as usual |
| omitted | no filter | through the model: a default scope that hides trashed records (paranoia's) drops them, though the total counts them |

The default scope is paranoia's, discard's `kept` when the model adds it, or your own on the column;
Lighthouse loads past it with `Support::SoftDeletes.with_trashed`, through Searchkick's `scope_results:`,
as Scout loads them `withTrashed()`. All of this needs trashed records in the index: a model that leaves
them out (`should_index?` returning false once trashed) finds none with `ONLY`.

### Keeping private records out of a search

A search answers from the index, not the table. **What must not be found must not be indexed**:
`should_index?` decides it per record, and the index follows as callbacks or jobs run. Until they do,
or for good if a job fails, the index still holds a record that must no longer be found.

A model's `search_results` scope, when it has one, is what a search of it may return, checked in the
database. Lighthouse loads the records Searchkick finds through it (Searchkick's `scope_results:`), so
a record the index still holds is not returned; the total counts it until the index is updated, a
page may come out short, and Searchkick logs it as a record the database does not have ("Records in
search index do not exist in database"). With pg_search the scope narrows the search itself, totals
included.

```ruby
scope :search_results, -> { where(post: Post.published) }
```

It is the model's, the same for every client: what depends on the user belongs in `@canQuery` or
`@canResolved`, or, with pg_search, in `@whereAuth`.

### `@canQuery` on a searched field

`@canQuery` checks the policy against each record the field's query would return. When the client
searches, those are the records the search finds: **all of them, not only the page** the field
returns, as PHP Lighthouse checks the hits of the Scout builder. With Searchkick that is one more engine
request, of 10,000 records at most, each loaded and checked: a search that finds more, within the result
window (a page cannot reach past it), is an error, `@canQuery checks every record the search finds, at
most 10000, and this one finds 12345. Narrow the search.`, passed to the client or replaced as
`action:` says, as any failed check. With pg_search, the scope's records, all of them. Its `model:` must be searchable, and with Searchkick its
`scopes:` are a schema error (PHP Lighthouse drops them). `@canResolved` checks only the records the
field returns, after it resolves.

### In a resolver of your own

`resolve_info.enhance_builder(Comment.all)` applies the field's search too (see
[resolvers.md](resolvers.md)). With pg_search it answers the relation, searched; with Searchkick, when
the client searched, a `Lighthouse::Search::Result`, as PHP Lighthouse answers Scout's builder:
`records(first:, offset:)` reads the records, `count` the total. The engine searches the model's whole
index, so the relation must be the model's: one narrowed beforehand (`Comment.where(...)`) is refused
with a `Lighthouse::DefinitionError`, since its conditions would be lost.

```graphql
type Query {
  found(search: String @search, postId: ID @eq(key: "post_id")): [Comment!]! @field(resolver: "Found")
}
```

```ruby
class Found
  def self.call(_object, _args, _context, resolve_info)
    found = resolve_info.enhance_builder(Comment.all)
    found.is_a?(Lighthouse::Search::Result) ? found.records(first: 20) : found.limit(20)
  end
end
```

### Choosing the engine

By default the engine is detected per model: Searchkick if it calls `searchkick`, else pg_search if it
includes `PgSearch::Model`. [`Config.search`](configuration.md#search) replaces that with one adapter
(`Lighthouse::Search::PgSearch.new`, `Lighthouse::Search::Searchkick.new`) or your own. An adapter
answers `searchable?(model, index)`, `relational?` and either `scope(relation, query)` (a relational one,
like pg_search) or `page(query, offset:, limit:)` returning `[records, total]`, and optionally
`result_window(query)` (10,000 when it does not, nil when it cannot tell) and `named?(model, index)`
(does `within:` name something of its own on the model: picked first when it does). This protocol is
experimental.

### Errors

| Case | PHP Lighthouse | Lighthouse |
| --- | --- | --- |
| Two `@search` arguments sent | `ScoutException` at run time | client error |
| An argument the engine cannot apply is sent | `ScoutException` at run time | same with Searchkick; none with pg_search |
| Model not searchable | `ScoutException` at run time | schema error at build, once the field's model is known |
| `within:` not a string | `DefinitionException` | schema error at build |
| Nested field (a relation) | `ScoutException` at run time | schema error with Searchkick; works with pg_search |
| Field has `scopes:`, `@builder`, `@whereAuth`, `@orderBy(column:)` | dropped silently | schema error with Searchkick; applied with pg_search |
| `@canQuery` with `scopes:` | dropped silently | schema error with Searchkick; applied with pg_search |
| A default value for a directive the engine cannot apply | `ScoutException` on every search | schema error with Searchkick; applied with pg_search |
| A mass mutation's `@search` sent as `null` | not a filter: "Would modify all models" | same |
| `@trashed` on a model whose `search_data` lacks the column | not a case: Scout indexes its own `__soft_deleted` (with `scout.soft_delete` on) | client error |
| A page past the result window | depends on the Scout driver | client error |
| `@canQuery` on more than 10,000 matches a page can reach | checks the hits Scout's `get()` returns | client error |
| `enhance_builder` given a narrowed relation | conditions dropped | `Lighthouse::DefinitionError` |

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
