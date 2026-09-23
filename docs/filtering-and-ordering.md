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

`@where(operator: "...")` supports the same operator vocabulary as
`@whereConditions`:

`EQ`, `NEQ`, `GT`, `GTE`, `LT`, `LTE`, `IN`, `NIN`, `CONTAINS`, `STARTS_WITH`,
`ENDS_WITH`, `IS_NULL`, `IS_NOT_NULL`.

```graphql
type Query {
  events(
    after: String @where(operator: "GTE", key: "starts_at")
    titleContains: String @where(operator: "CONTAINS", key: "title")
  ): [Event!]! @all
}
```

## Ordering — `@orderBy`

Sort the result by one or more columns. The client passes a list of clauses, each
with a `column` and an `order` (`ASC`/`DESC`); clauses apply in order.

```graphql
type Query {
  users(orderBy: [OrderByClause!] @orderBy): [User!]! @all

  # query:
  # users(orderBy: [{ column: NAME, order: ASC }, { column: CREATED_AT, order: DESC }])
}
```

`@orderBy` also accepts `{ field:, direction: }` clause shapes, so it slots into
existing client conventions.

## Complex where conditions

For a flexible, client-controlled `WHERE` builder, use `@whereConditions`.
Lighthouse generates the input and column-enum types automatically — you only
declare the allowed columns.

```graphql
type Query {
  people(
    where: _ @whereConditions(columns: ["age", "type", "height"])
  ): [Person!]! @all
}
```

Clients can then build dynamic conditions with `AND` / `OR` / operators:

```graphql
{
  people(
    where: {
      AND: [
        { column: AGE, operator: GT, value: 37 }
        { OR: [
            { column: TYPE, value: "Actor" }
            { column: HEIGHT, operator: GTE, value: 150 }
        ] }
      ]
    }
  ) { name }
}
```

The generated `SQLOperator` enum covers `EQ`, `NEQ`, `GT`, `GTE`, `LT`, `LTE`,
`IN`, `NIN`, `CONTAINS`, `STARTS_WITH`, `ENDS_WITH`, `IS_NULL`, `IS_NOT_NULL`.

### `@whereHasConditions`

Filter by the existence of a related record, with conditions applied to the
relation:

```graphql
type Query {
  users(
    hasPosts: _ @whereHasConditions(columns: ["status"])
  ): [User!]! @all
}
```

The relation is inferred from the `has<Relation>` argument name (`hasPosts` →
`posts`), or specified with `relation:`.

## How columns are resolved

Column names from enums (e.g. `CREATED_AT`) and arguments (`minAge`) are mapped to
real columns through one central rule (`Lighthouse::Support::Naming`): ALLCAPS
enum keys are downcased, and camelCase is converted to snake_case. This keeps
client-facing GraphQL idiomatic while matching your Rails schema.
