# Mutations

Write a mutation as a [class in `app/graphql/mutations`](resolvers.md) when it
carries business logic. Plain create, update, upsert and delete need no Ruby:
`@create`, `@createMany`, `@update`, `@updateMany`, `@upsert`, `@upsertMany` and
`@delete` work on the model a field returns, through ActiveRecord. Nested input
saves its associations too. The model's validations, callbacks and associations
behave exactly as they do anywhere else in your app.

```graphql
type Mutation {
  createPost(title: String!, body: String): Post! @create
  updatePost(id: ID!, title: String, body: String): Post! @update
  createPosts(inputs: [CreatePostInput!]!): [Post!]! @createMany
  updatePosts(inputs: [UpdatePostInput!]!): [Post!]! @updateMany
}
```

## How arguments become attributes

Each argument the client sends becomes one attribute, under its `snake_case`
name. Arguments the client leaves out are not assigned at all, so `@update` only
changes what was sent.

- **`@rename(attribute:)`** maps an argument (or input field) to a differently
  named attribute:
  ```graphql
  createPost(title: String!, content: String @rename(attribute: "body")): Post @create
  ```
- **`@spread`** merges an input object's fields into the arguments. This is the
  usual shape for a single `input:` argument:
  ```graphql
  createPost(input: CreatePostInput! @spread): Post @create
  ```
- **`@inject(context:, name:)`** sets a server-side attribute from the context,
  so clients cannot choose it:
  ```graphql
  createPost(title: String!): Post @create @inject(context: "current_user.id", name: "author_id")
  ```
- **`model:`** names the model when it is not the field's return type:
  `@create(model: "Admin::Post")`.

## The directives

### `@create`

Builds the model from the arguments and saves it.

### `@createMany`

The field takes exactly one argument, a list of input objects. Lighthouse creates
one model per item.

### `@update`

Finds the model by its primary key and updates it. The key comes from the
argument named after the primary key (`id`), or the one renamed to it. A missing
record raises `Couldn't find Post with 'id'=…`, the same wording as Rails.

### `@updateMany`

Like `@createMany`, but each item carries its primary key. Without a key the
mutation fails with `Missing primary key for update.`

### `@upsert` / `@upsertMany`

Update the model the input identifies, or create it:

- With `identifyingColumns: ["email"]`, the model is matched on those columns.
  All of them must be given and non-null.
- Otherwise it is matched on the primary key.
- When nothing matches, the model is created, with the given id if there is one.

```graphql
type Mutation {
  upsertUser(email: String!, name: String!): User @upsert(identifyingColumns: ["email"])
  upsertPosts(inputs: [UpsertPostInput!]!): [Post!]! @upsertMany
}
```

### `@delete`

Destroys the models the field's filter arguments select, running their callbacks,
and returns them: a list for a list field, else the first or `null`.

```graphql
type Mutation {
  deletePost(id: ID! @whereKey): Post @delete
  deletePosts(ids: [ID!]! @whereKey): [Post!]! @delete
  deleteDrafts(authorId: ID! @eq): [Post!]! @delete(scopes: ["drafts"])
}
```

Without a filter argument, it refuses to run, since it would delete every row:
`Would modify all models, use an argument to filter.` A model whose callbacks
abort the destroy is reported next to the data:
`Could not modify model Post with ID 1.`

### `@forceDelete` and `@restore`

`@forceDelete` permanently removes soft deleted models and `@restore` un-deletes
them. They work very much like `@delete` (required filter arguments, the models
returned, `model:` and `scopes:`), but also find the models the soft-delete
strategy hides. See [Soft deletes & global
scopes](directives.md#soft-deletes-global-scopes).

```graphql
type Mutation {
  forceDeletePost(id: ID! @whereKey): Post @forceDelete
  restorePost(id: ID! @whereKey): Post @restore
}
```

## Validation errors

When a model does not save, the mutation fails with PHP Lighthouse's error
format. Messages are keyed by **argument path**, including the path inside a
spread input or the index of a list item:

```json
{
  "data": { "createPosts": null },
  "errors": [{
    "message": "Validation failed for the field [createPosts].",
    "extensions": {
      "validation": {
        "inputs.1.title": ["Title can't be blank"],
        "inputs.2.title": ["Title can't be blank"]
      }
    }
  }]
}
```

Messages are the models' `full_message`s, so they follow your locale files. A
`:base` error is keyed by the field name. For rules that don't belong to the
model, add a [`@validator`](validation.md). It runs before the model is saved.

## Transactions

Each mutation field runs in a database transaction. If one item of a
`@createMany` is invalid, the others are rolled back, and the response lists every
invalid item, not just the first. To turn this off:

```ruby
Lighthouse.configure { |config| config.transactional_mutations = false }
```

## Combining with authorization and cache invalidation

```graphql
type Mutation {
  createPost(input: CreatePostInput! @spread): Post!
    @create
    @guard
    @canModel(ability: "create")
    @clearCache(type: "Query", field: "latestPosts")

  updatePost(input: UpdatePostInput! @spread): Post!
    @update
    @canFind(ability: "update", find: "input.id")
    @clearCache(type: "Post", idSource: { argument: "input.id" })
}
```

The order you write them in does not matter: authentication runs first, then
authorization, validation, and the save; `@clearCache` acts once the save has
succeeded. See [authorization.md](authorization.md) and [caching.md](caching.md).

## Nested mutations

An input field named after one of the model's associations carries **operations**
on that association, and its type declares which are allowed. This is PHP
Lighthouse's nested mutation API, run through ActiveRecord:

```graphql
type Mutation {
  createPost(input: CreatePostInput! @spread): Post @create
  updatePost(input: UpdatePostInput! @spread): Post @update
}

input CreatePostInput {
  title: String!
  author: AuthorBelongsTo            # Post belongs_to :author
  comments: CommentsHasMany          # Post has_many :comments
  tags: TagsBelongsToMany            # Post has_many :tags, through: :taggings
}

input AuthorBelongsTo { connect: ID create: CreateUserInput update: UpdateUserInput upsert: UpsertUserInput }
input CommentsHasMany { create: [CreateCommentInput!] connect: [ID!] }
input TagsBelongsToMany { connect: [ID!] sync: [ID!] create: [CreateTagInput!] }
```

```graphql
mutation {
  createPost(input: {
    title: "Hello"
    author: { connect: 1 }
    comments: { create: [{ body: "First!" }] }
    tags: { sync: [3, 4] }
  }) { id author { name } comments { body } tags { name } }
}
```

### Operations by association

| Association | Operations |
| --- | --- |
| `belongs_to` | `connect: ID`, `create`, `update`, `upsert`, `disconnect: Boolean`, `delete: Boolean` |
| `belongs_to …, polymorphic: true` | `connect: { type: String!, id: ID! }`, `disconnect`, `delete` |
| `has_one` (also `as:`) | `create`, `update`, `upsert`, `delete: ID` |
| `has_many` (also `as:`) | `create`, `update`, `upsert`, `connect: [ID!]`, `disconnect: [ID!]`, `delete: [ID!]` |
| `has_many :through`, `has_and_belongs_to_many` | `sync`, `syncWithoutDetaching`, `create`, `update`, `upsert`, `connect`, `disconnect: [ID!]`, `delete: [ID!]` |

- `create`, `update` and `upsert` take input objects, or lists of them for
  collections. Those inputs may nest further operations, to any depth.
- `null` operations are ignored, and `disconnect`/`delete` only act when `true`.
- A polymorphic `connect`'s `type` is a model name: `"Task"`, or an enum value
  such as `TASK`.
- `has_one` refuses a second `create`: "Cannot create a related model: a Post
  already exists for this Task. Use upsert to modify the existing model." An
  `upsert` without an id updates the existing one.
- Operations run in PHP Lighthouse's fixed order, whatever order the client
  writes them in.

### Pivot values

For a `has_many :through`, `connect`, `sync` and `syncWithoutDetaching` accept
inputs with an `id` plus columns of the join model:

```graphql
input UpdateUserRoles { sync: [RolePivot!] connect: [RolePivot!] }
input RolePivot { id: ID! expiresAt: String }  # role id + role_assignments.expires_at
```

`has_and_belongs_to_many` has no join model, so it takes plain ids only.

### When it saves, and what fails

Each record is saved **once**:

1. its attributes are assigned;
2. `belongs_to` operations set its foreign keys (creating or updating the parent
   records first);
3. it is saved;
4. the operations on associations pointing back at it run.

Validation errors from any level are keyed by their full input path, e.g.
`input.author.create.name`. The whole mutation is one transaction, so a failure
anywhere rolls everything back.

### Operations as arguments

`@create`, `@update`, `@upsert` (with optional `identifyingColumns`) and `@delete`
on an argument or input field, with `relation:`, run that operation on the
association instead:

```graphql
input UpdateUserInput {
  id: ID!
  newTask: CreateTaskInput @create(relation: "tasks")
  tasks: [UpsertTaskInput!] @upsert(relation: "tasks", identifyingColumns: ["name"])
  deleteTasks: [ID!] @delete(relation: "tasks")
  deleteAvatar: Boolean @delete(relation: "avatar")
}
```

### Permissions

As in PHP Lighthouse, nested `update`, `upsert`, `delete` and `disconnect` find
records by primary key **in the whole table**, not only among the parent's
current children. A nested `update` of another user's task moves the task to
this user. Authorize the mutation field accordingly, with `@can*` checks on the
field or validators that restrict the ids. There is no per-operation permission
mechanism.
