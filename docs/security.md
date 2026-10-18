# Query Complexity & Depth

A single GraphQL request can ask for a lot: a page of 1,000 posts, each with
its 1,000 comments, each with its author. graphql-ruby can refuse such a query
**before it runs**. It scores the query from the fields it selects, then
compares the score with a limit you set. Lighthouse doesn't add a scorer of its
own. It gives your SDL's fields their cost, and graphql-ruby's analyzers
(`GraphQL::Analysis::MaxQueryComplexity`, `MaxQueryDepth`) do the rest. PHP
Lighthouse works the same way on top of webonyx's validation rules.

## Setting the limits

The limits are graphql-ruby's own schema settings. Set them on the schema
Lighthouse builds:

```ruby
# app/graphql/app_schema.rb
AppSchema = Lighthouse::GraphQL::RbLightHouse.get_schema(options: { using: { GraphQL::Dataloader => {} } })

AppSchema.max_complexity(300)   # refuse queries that score over 300
AppSchema.max_depth(12)         # refuse queries nested deeper than 12 fields
AppSchema.disable_introspection_entry_points if Rails.env.production?
```

You can also set them on a base schema class you hand to `get_schema` with
`options: { base_schema: MyBaseSchema }`.

A query over the limit isn't executed. Its response holds only the error:

```json
{ "errors": [{ "message": "Query has complexity of 3001, which exceeds max complexity of 300" }] }
```

To give one request a different limit, pass it to `execute`:
`AppSchema.execute(query, max_complexity: 1000)`.

## How a query is scored

Each selected field adds its cost, and a field's cost includes the cost of the
fields selected inside it (its *child complexity*). By default, graphql-ruby
counts **1 per field**:

```graphql
{ posts { id title author { name } } }   # posts 1 + id 1 + title 1 + author 1 + name 1 = 5
```

Lighthouse changes that default in three places:

| Field | Cost |
| --- | --- |
| Paginated: `@paginate`, or `@hasMany` / `@belongsToMany` / `@morphMany` / `@morphToMany` given `type:` | `1 + child complexity × first` |
| Carrying `@complexity` | `1 + child complexity × first`, or the `complexity` of the analyzer it names (below) |
| Resolved by a `GraphQL::Schema::Resolver` class, by convention (`Query.search` → `Resolvers::Search`) or through `@field` | the `complexity` that class declares (default: `1 + child complexity`) |

Paginated fields scale by `first`, which already holds the page size when the
client leaves it out (the directive's `defaultCount`, else
`pagination_default_count`). That way, asking for 1,000 items costs 1,000 times
as much as asking for one:

```graphql
{ posts(first: 100) { data { id title } } }   # 1 + (data 1 + id 1 + title 1) × 100 = 301
```

For a connection (`type: CONNECTION`) the same rule applies, multiplying
everything under `edges` and `pageInfo`, as PHP Lighthouse does. It replaces
graphql-ruby's own connection scaling, which knows nothing about `defaultCount`.

## `@complexity`

Customize a field's cost, or attach a graphql-ruby analyzer to the schema.

```graphql
type Query {
  "1 + child complexity × first, as on a paginated field."
  search(first: Int, term: String!): [Post!]! @complexity

  "What Analyzers::PostsComplexity says."
  posts(includeFullText: Boolean): [Post!]! @all @complexity(resolver: "PostsComplexity")
}
```

| Argument | Meaning |
| --- | --- |
| `resolver: String` | A `GraphQL::Analysis::Analyzer` subclass, looked up in `namespaces[:analyzers]` (`Analyzers::PostsComplexity`). A name containing `::` is taken as written. |

Without `resolver:`, the field costs `1 + child complexity × first` (`first` is 1
when the field has no such argument).

### The analyzer

`resolver:` names a graphql-ruby analyzer, written as graphql-ruby's
[analysis guide](https://graphql-ruby.org/queries/ast_analysis.html) writes it.
Lighthouse installs it on the schema, as `query_analyzer Analyzers::PostsComplexity`
would, once however many fields name it. Like every graphql-ruby analyzer, it
runs on **every query**, not only those that select the field:

```ruby
# app/graphql/analyzers/agent_bot_analyzer.rb
class Analyzers::AgentBotAnalyzer < GraphQL::Analysis::Analyzer
  def analyze? = subject.context[:current_user].is_a?(AgentBot)

  def on_enter_field(node, _parent, visitor)
    @refused = true if visitor.parent_type_definition == visitor.query.schema.mutation
  end

  def result
    GraphQL::AnalysisError.new('Bots may not run mutations') if @refused
  end
end
```

A field naming a plain analyzer costs what a bare `@complexity` gives. An
analyzer that can't be found, or a class that isn't a
`GraphQL::Analysis::Analyzer`, stops the schema from building
(`Lighthouse::DefinitionError`).

### Giving the field its cost: `Lighthouse::GraphQL::ComplexityAnalyzer`

Include the concern, and the analyzer's `complexity` becomes the cost of the
fields naming it. It's the `complexity` graphql-ruby gives a field or a
`GraphQL::Schema::Resolver`: a number, added to the cost of the field's
selection, or a proc called with the query's context, the field's arguments
(snake_case Symbol keys) and the child complexity, returning the whole cost.

As with resolvers and mutations, the concern goes once in a base class, and each
analyzer that prices a field inherits from it:

```ruby
# app/graphql/analyzers/base_complexity.rb
class Analyzers::BaseComplexity < GraphQL::Analysis::QueryComplexity
  include Lighthouse::GraphQL::ComplexityAnalyzer
end

# app/graphql/analyzers/posts_complexity.rb
class Analyzers::PostsComplexity < Analyzers::BaseComplexity
  complexity ->(_context, args, child_complexity) { child_complexity * (args[:include_full_text] ? 3 : 2) }
end
```

`complexity 5` gives a fixed cost: 5 plus the selection's. A subclass inherits
its superclass's `complexity`. Without one, the field costs what a bare
`@complexity` gives. The cost wins over the pagination default.

The class is still an analyzer. With a `result` of its own, it runs on every
query like any other, so one class can price a field and act on the whole query,
for example refusing a guest's query over a smaller budget:

```ruby
class Analyzers::PostsComplexity < Analyzers::BaseComplexity
  complexity 10

  def result
    cost = max_possible_complexity
    return if query.context[:current_user] || cost <= 200

    GraphQL::AnalysisError.new("Guests may run queries up to 200, this one costs #{cost}")
  end
end
```

Without a `result` of its own, it only gives costs, and graphql-ruby skips it
during analysis.

## Resolver classes declare their own cost

A root field without a resolving directive resolves to a
`GraphQL::Schema::Resolver` by convention (see [resolvers.md](resolvers.md)).
That class's `complexity` applies, exactly as with graphql-ruby's
`field :search, resolver: Resolvers::Search`:

```ruby
class Resolvers::Search < Resolvers::BaseResolver
  complexity ->(_ctx, args, child_complexity) { args[:limit] * child_complexity }

  def resolve(term:, limit:) = Post.search(term).limit(limit)
end
```

The same goes for a class named by `@field(resolver:)`, and for a mutation
class. An explicit `@complexity` on the field takes precedence over the class.

## Reading the score

`BuildExtensionsResponse` carries the score as `query_complexity`. It's the same
number `max_complexity` is checked against, so you can report it to clients or
to your metrics:

```ruby
Lighthouse::Events.listen(Lighthouse::Events::BuildExtensionsResponse) do |event|
  Lighthouse::Events::ExtensionsResponse.new('complexity', event.query_complexity)
end
# => { "data" => {...}, "extensions" => { "complexity" => 301 } }
```

The query is scored only while something listens to that event, and a query
that failed validation is never scored (`query_complexity` is `nil`). A query
refused for going over `max_complexity` still carries its score, so you can log
what was refused. See
[events.md](events.md#execution-events).

To score a query yourself, run graphql-ruby's analyzer:

```ruby
query = GraphQL::Query.new(AppSchema, '{ posts(first: 10) { data { id } } }')
GraphQL::Analysis.analyze_query(query, [GraphQL::Analysis::QueryComplexity]).first # => 21
```

`QueryComplexity` logs a warning unless the schema chooses an algorithm with
`AppSchema.complexity_cost_calculation_mode(:future)`. `max_complexity` and
`query_complexity` always use the `:future` algorithm.

## Rate limiting

[`@throttle`](directives.md#throttle) caps how often one client may call a field —
a login, a search, an expensive mutation:

```graphql
type Mutation {
  login(email: String!, password: String!): User @throttle(maxAttempts: 5, decayMinutes: 1)
}
```

Attempts are counted in [`cache_store`](configuration.md#cache_store), so use a store
the app servers share (Redis, Solid Cache) in production; `:null_store` counts
nothing. A client is the signed-in user, else the `:remote_ip` the controller concern
puts in the context (override `graphql_context` to set another). A refused call never
reaches `@guard` or the resolver.
