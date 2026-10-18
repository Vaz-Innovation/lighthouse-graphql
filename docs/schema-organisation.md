# Schema Organisation

Lighthouse reads your schema from a single entrypoint, `graphql/schema.graphql`
by default (`config.schema_path`), as PHP Lighthouse does. As the schema grows,
you split it across files, and the entrypoint imports them.

## Schema imports

```
graphql/
|-- schema.graphql
|-- user.graphql
```

An import starts with `#import`, followed by the path of the imported file,
relative to the file the import is in:

```graphql
type Query {
  user: User
}

#import user.graphql
```

The contents of `user.graphql` are pasted in where the import is:

```graphql
type Query {
  user: User
}

type User {
  name: String!
}
```

An imported file can import others. A file is read once, so importing it twice,
or importing a file that imports it back, adds nothing more.

Only the entrypoint and the files it imports make up the schema. A `.graphql`
file in the folder that nothing imports is not part of it. A missing import
fails the build: "Did not find GraphQL schema import at …".

### Wildcard imports

```
graphql/
|-- schema.graphql
|-- blog/
    |-- post.graphql
    |-- category.graphql
```

To import every file in `blog/` at once, use a glob (Ruby's `Dir.glob`), which
imports the files in name order:

```graphql
#import blog/*.graphql
```

`#import **/*.graphql` imports every file below the entrypoint's folder.

## Type extensions

A type is defined once. Defining it twice is an error that points at
`extend`. This applies even across files:

```
Duplicate definition Query found when parsing the schema. Define a type once and add to it from other files with `extend type Query`.
```

PHP Lighthouse keeps the last definition and drops the earlier one without a
word. Lighthouse here makes that an error, so a type's fields are never lost.

Say `Post` is defined in `post.graphql`:

```graphql
type Post {
  title: String
  author: User @belongsTo
}
```

and `schema.graphql` imports it:

```graphql
#import post.graphql
```

To add the queries that fetch posts, you could add them to the `Query` type in
`schema.graphql`. It is usually better to keep queries next to the type they
return. Make sure `schema.graphql` defines `Query`, even with no fields:

```graphql
type Query
```

Then extend `Query` in `post.graphql`:

```graphql
type Post {
  title: String
  author: User @belongsTo
}

extend type Query {
  posts: [Post!]! @paginate
}
```

The fields of the `extend type` are merged into the type's definition, and the
directives on them work as on any field. Besides object types, you can extend
`input`, `interface`, `enum`, `union` and `scalar` types:

```graphql
extend input PostFilter { authorId: ID @eq(key: "author_id") }
extend enum Role { EDITOR }
extend union SearchResult = Comment
```

The final schema always has one type per name. An extension of a type that is
not defined is an error, and so is an extension that redefines a field:

```
Could not find a base definition User of kind ObjectTypeExtension to extend.
Duplicate definition title found when merging.
```

The root types `Query`, `Mutation` and `Subscription` are the exception: an
`extend type Mutation` with no `type Mutation` anywhere defines it.

## How the schema is built

The build runs these phases in order, as PHP Lighthouse's `ASTBuilder` does:

1. The entrypoint and its imports are read (`Lighthouse::GraphQL::SchemaStitcher`),
   along with what `BuildSchemaString` listeners add
   ([events.md](events.md)).
2. Every type is defined once (`Lighthouse::GraphQL::DocumentAST`).
3. Type extensions are merged into their types.
4. Type and field manipulators run: `@hide`/`@show`, `@model`, `@paginate`
   and the relation directives' `type:`, `@softDeletes`, `@node`.
5. Argument manipulators run: `@whereConditions`, `@whereHasConditions` and
   `@orderBy` replace the `_` placeholder with the types they generate
   ([filtering-and-ordering.md](filtering-and-ordering.md)). An argument still
   typed `_` after this phase is an error.
6. `ManipulateAST` listeners see the document.

## IDE support

An IDE reads the `.graphql` files as they are written, so it does not know
Lighthouse's directives, the types the build generates, or the `_` placeholder.
Lighthouse writes two files that declare them:

- `schema-directives.graphql`: every directive the schema uses and does not declare.
- `programmatic-types.graphql`: the generated types (paginators, the `@orderBy`
  and `@whereConditions` inputs, ...) and `scalar _`.

`graphql.config.yml` (written by `lighthouse:install`) points the GraphQL
plugins of VS Code and JetBrains IDEs at them, next to every `.graphql` file:

```yaml
schema:
  - graphql/**/*.graphql
  - schema-directives.graphql
  - programmatic-types.graphql
```

In development, Lighthouse rewrites both files on boot and on every reload when
the app has a `graphql.config.yml` (`config.ide_helper`). Elsewhere, run
`bin/rails lighthouse:ide_helper`. No type is in two of the three sources, because
graphql-js, which the IDE plugins build the schema with, rejects a type defined
twice.

The IDE sees the files as one schema, imports or not. Without the generated
files it reports `Unknown type "_"` and unknown directives.
