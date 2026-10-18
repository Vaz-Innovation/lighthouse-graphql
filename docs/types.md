# Unions, Interfaces and Scalars

The SDL declares every type. Object types resolve their fields through
directives, the default reader, or a [type class](resolvers.md#type-classes).
Three more kinds need Ruby to say how their values work:

- a **union** or an **interface** needs to know which object type each value is;
- a custom **scalar** needs to know how to read its values from a query and write
  them to a response.

Lighthouse answers both as [PHP Lighthouse](https://lighthouse-php.com/master/the-basics/types.html)
does by default, and lets you take over with a class, in graphql-ruby's
`app/graphql/types` structure, or with a directive.

## Unions and interfaces

```graphql
type Query {
  search(term: String!): [SearchResult!]!
  latestActivity: [Authored!]!
}

union SearchResult = Post | User

interface Authored {
  id: ID!
  author: User!
}

type Post implements Authored { id: ID! title: String! author: User! }
type Comment implements Authored { id: ID! body: String! author: User! }
```

A resolver returns records, of any of the types:

```ruby
class Resolvers::Search < Resolvers::BaseResolver
  def resolve(term:)
    Post.where('title LIKE ?', "%#{term}%").to_a + User.where('name LIKE ?', "%#{term}%").to_a
  end
end
```

```graphql
{
  search(term: "Grace") {
    __typename
    ... on Post { title }
    ... on User { name }
  }
}
```

### The default

Each value resolves to the first of these that is one of the union's (or the
interface's) types:

1. a Hash's `__typename` (`{ __typename: 'Movie', title: 'Heat' }`);
2. the type named after the value's class (a `Post` record is a `Post`), or after
   one of its superclasses, so an `Admin < User` STI record is a `User` when no
   `Admin` type exists;
3. the type whose [`@model`](directives.md#model) names the value's model. With
   `type Article @model(class: "Post")`, a `Post` record is an `Article`.

Most schemas need nothing else.

### A type class

When the default is not enough, say when the values are Hashes from a search
service rather than records, write the union's class as graphql-ruby does
(`rails g graphql:union SearchResult`),
`Types::<Name>Type` including `Lighthouse::GraphQL::Type`, with `resolve_type`.
It returns a type name, or a type class, which stands for the SDL type of its
`graphql_name`:

```ruby
# app/graphql/types/search_result_type.rb
module Types
  class SearchResultType < BaseUnion
    include Lighthouse::GraphQL::Type

    def self.resolve_type(object, context)
      return unless object.is_a?(Hash)

      object['index'] == 'users' ? Types::UserType : 'Post'
    end
  end
end
```

An interface's goes in graphql-ruby's `definition_methods`:

```ruby
# app/graphql/types/authored_type.rb
module Types
  module AuthoredType
    include BaseInterface
    include Lighthouse::GraphQL::Type

    definition_methods do
      def resolve_type(object, context)
        object['index'] == 'comments' ? 'Comment' : 'Post' if object.is_a?(Hash)
      end
    end
  end
end
```

`nil` leaves the value to the default, so the class only handles the cases that
need it. The SDL still declares the members: `possible_types` in the class are
ignored.

### `@union` and `@interface`

PHP Lighthouse's directives name the class in the schema instead. It has
`resolve_type(object, context)` or `call(object, context)`, and is looked up in the
types namespace (nested names too), then as written:

```graphql
union SearchResult @union(resolveType: "SearchResultResolver") = Post | User
interface Authored @interface(resolveType: "AuthoredResolver") { id: ID! }
```

The directive comes first, then the type class, then the default.

### When nothing resolves a value

A value no step resolves, or one resolved to a type the union or interface does
not include, raises `Lighthouse::DefinitionError`. It is a server bug, not a client
error, and the message names the ways out:

```text
Lighthouse could not tell the type of a Tag in the union SearchResult (Post | User):
name a type after its class, map one to it with @model(class: "Tag"), or resolve
it in Types::SearchResultType.resolve_type or with @union(resolveType:).
```

A `@union` or `@interface` naming no class, or a type class of another kind than
its SDL type (a union class for an interface), fails when the schema is built.

## Scalars

```graphql
"An ISO 8601 date and time."
scalar DateTime

type Post {
  createdAt: DateTime!
}

type Query {
  latestActivity(since: DateTime): [Authored!]!
}
```

Write the scalar's class with graphql-ruby's `rails g graphql:scalar DateTime`,
`Types::<Name>Type` including `Lighthouse::GraphQL::Type`:

```ruby
# app/graphql/types/date_time_type.rb
module Types
  class DateTimeType < BaseScalar
    include Lighthouse::GraphQL::Type

    def self.coerce_input(value, context)
      Time.iso8601(value.to_s)
    rescue ArgumentError
      raise GraphQL::CoercionError, "#{value.inspect} is not an ISO 8601 date and time"
    end

    def self.coerce_result(value, context)
      value.utc.iso8601
    end
  end
end
```

- `coerce_input` reads an argument or variable. The resolver gets its result, here a
  `Time`. Raising `GraphQL::CoercionError` (or returning `nil`) makes the argument
  invalid, and the client gets the message.
- `coerce_result` writes a value a field returns, here `Post#created_at`.

`@scalar(class:)`, PHP Lighthouse's directive, names the class in the schema
instead, looked up in the types namespace, then as written:

```graphql
scalar Money @scalar(class: "Money::GraphQLScalar")
```

A scalar with neither passes its values through unchanged. A `@scalar` naming no
class with `coerce_input` and `coerce_result` fails when the schema is built.

## Opting in, and base classes

Only a class including `Lighthouse::GraphQL::Type` counts: any other
`Types::SearchResultType` or `Types::DateTimeType`, such as the ones a graphql-ruby
app already has, is left alone. The concern can be included in a subclass of
`GraphQL::Schema::Object`, `Union` or `Scalar`, or in a module including
`GraphQL::Schema::Interface`.

The classes are looked up in [`namespaces[:types]`](configuration.md#namespaces)
(default `['Types']`). When the schema's `base_types` name a base for a kind,
graphql-ruby builds the SDL's types of that kind from it, and a type class of that
kind must inherit from it, or the schema does not build:

```ruby
AppSchema = Lighthouse::GraphQL::RbLightHouse.get_schema(
  options: {
    base_types: {
      object: Types::BaseObject,
      union: Types::BaseUnion,
      interface: Types::BaseInterface,
      scalar: Types::BaseScalar
      # resolver:, mutation:, subscription: (resolvers.md#handing-the-bases-to-the-schema)
    }
  }
)
```
