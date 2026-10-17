# Subscriptions

A subscription lets a client ask for a stream of updates: it sends a `subscription`
operation once, and the server sends a result each time something it cares about
happens. Lighthouse builds on [graphql-ruby's subscriptions](https://graphql-ruby.org/subscriptions/overview.html)
and keeps [PHP Lighthouse's model](https://lighthouse-php.com/master/subscriptions/getting-started.html):

- a `Subscription` field is declared in the SDL, and **resolves by convention** to a class;
- a mutation announces what it did with [`@broadcast`](#broadcast-from-a-mutation);
- the class decides **who may subscribe** (`authorize?`), **who receives** a broadcast (`filter?`) and **what they receive** (`resolve_payload`).

```graphql
type Subscription {
  postUpdated(author: ID): Post
}

type Mutation {
  updatePost(id: ID!, title: String): Post! @update @broadcast(subscription: "postUpdated")
}
```

```ruby
# app/graphql/subscriptions/post_updated.rb  (rails generate lighthouse:subscription PostUpdated)
module Subscriptions
  class PostUpdated < Lighthouse::GraphQL::Subscription
    def filter?(post, author: nil)
      author.nil? || post.author_id.to_s == author.to_s
    end
  end
end
```

## Enabling a backend

graphql-ruby delivers subscriptions through a *backend* that stores who subscribed
and sends the updates: ActionCable (bundled), or a gem such as Pusher or Ably.
Lighthouse needs none of its own; give the schema one. `get_schema` passes the
`using:` option to graphql-ruby, as `use` does in a class-based schema:

```ruby
# app/graphql/app_schema.rb
AppSchema = Lighthouse::GraphQL::RbLightHouse.get_schema(
  options: { using: { GraphQL::Subscriptions::ActionCableSubscriptions => {} } }
)
```

Options of the backend go in the hash (`{ ActionCableSubscriptions => { namespace: 'my-app' } }`).
Assign the schema to a constant: a [queued](#queueing) broadcast finds it by name.

Then add the channel graphql-ruby documents, which runs the operation and keeps
the client's subscription ids ([the full example](https://graphql-ruby.org/subscriptions/action_cable_implementation.html)):

```ruby
class GraphqlChannel < ApplicationCable::Channel
  def subscribed
    @subscription_ids = []
  end

  def execute(data)
    result = AppSchema.execute(
      data['query'],
      variables: data['variables'] || {},
      operation_name: data['operationName'],
      context: { channel: self, current_user: current_user }
    )
    @subscription_ids << result.context[:subscription_id] if result.context[:subscription_id]
    transmit(result: result.to_h, more: result.subscription?)
  end

  def unsubscribed
    @subscription_ids.each { |id| AppSchema.subscriptions.delete_subscription(id) }
  end
end
```

Use a real ActionCable adapter (Redis, PostgreSQL, Solid Cable), not `async`: the
broadcast is often triggered from a job or a console, another process than the
one holding the sockets. The root a broadcast carries travels through
ActionCable's serialization, so an Active Record model must be serializable with
GlobalID, as it is in a Rails app.

## Defining subscription fields

A field of the `Subscription` type needs nothing but its SDL, and then
**every broadcast reaches every subscriber, unchanged**: `@broadcast` hands the
mutation's result to the subscription, which resolves the field with it.

```graphql
type Subscription {
  postCreated: Post
}
```

For anything more, write the class. `Subscription.postUpdated` resolves to
`Subscriptions::PostUpdated`, looked up in `Config.namespaces[:subscriptions]`
(default `['Subscriptions']`) each time it is needed, so code reloading works.
`rails generate lighthouse:subscription PostUpdated` writes it. It inherits from
`Lighthouse::GraphQL::Subscription`, or from `GraphQL::Schema::Subscription`
directly, if you would rather have graphql-ruby's behaviour alone.

Like a query or a mutation class, it declares neither the arguments nor the return
type: the SDL does. The field's arguments arrive as `snake_case` keywords.

### The hooks

`Lighthouse::GraphQL::Subscription` maps the hooks of PHP Lighthouse's
`GraphQLSubscription` onto graphql-ruby's. All are optional.

| PHP Lighthouse | Here | Maps onto | Default |
| --- | --- | --- | --- |
| `authorize(Subscriber, Request): bool` | `authorize?(**args)` | `authorized?`, on the subscription request only | `true` |
| `filter(Subscriber, $root): bool` | `filter?(root, **args)` | `update` returns `NO_UPDATE` when it is false | `true` |
| `resolve($root, $args, $context, $info)` | `resolve_payload(root, **args)` | the value `update` returns | `root` |
| `encodeTopic` / `decodeTopic` | `self.topic_for(arguments:, field:, scope:)` | graphql-ruby's topic | the field and its scope |

- **`args`** are the arguments the client *subscribed* with, in `snake_case`.
  `object` is the broadcast root in `filter?` and `resolve_payload`, and
  `context` is the *subscriber's*: graphql-ruby stores it with the subscription and
  replays it for each update, so `context[:current_user]` is whoever subscribed.
- **`authorize?`** returning false refuses the subscription: the client gets
  `Unauthorized subscription request.` and nothing is registered. Raise a
  `GraphQL::ExecutionError` to say more. It is not called again for the updates.
- **`filter?`** is where a subscriber is turned down for one broadcast.

```ruby
module Subscriptions
  class OrderShipped < Lighthouse::GraphQL::Subscription
    def authorize?(**)
      context[:current_user].present?
    end

    def filter?(order, **)
      order.user_id == context[:current_user].id
    end

    def resolve_payload(order, **)
      order.decorate
    end
  end
end
```

Everything else graphql-ruby's `GraphQL::Schema::Subscription` offers still applies:
`subscribe(**args)` to answer the subscription request with an initial payload
(nothing by default), `unsubscribe` to end a subscription from the server,
`ready?`, `subscription_scope`.

## `@subscription`

A class that does not follow the naming convention, or lives elsewhere, is named
with `@subscription(class:)`:

```graphql
directive @subscription(class: String!) on FIELD_DEFINITION
```

```graphql
type Subscription {
  postUpdated(author: ID!): Post @subscription(class: "Blog::PostUpdatedSubscription")
}
```

The name is looked up in `Config.namespaces[:subscriptions]` like the conventional
one, so `class: "PostUpdated"` finds `Subscriptions::PostUpdated`, and a name with
`::` is used as it is. A class that does not exist, or is not a
`GraphQL::Schema::Subscription`, raises `Lighthouse::DefinitionError`.
`@guard`, `@can*` and the other wrapping directives work on a subscription field
as on any other.

## Broadcast from a mutation

`@broadcast` triggers a subscription after its field has resolved:

```graphql
directive @broadcast(subscription: String!, shouldQueue: Boolean) repeatable on FIELD_DEFINITION
```

```graphql
type Mutation {
  createPost(input: CreatePostInput! @spread): Post! @create @broadcast(subscription: "postCreated")
  updatePost(input: UpdatePostInput! @spread): Post!
    @update
    @broadcast(subscription: "postUpdated", shouldQueue: false)
    @broadcast(subscription: "postsOfAuthor")
}
```

- The **result of the field is the root** the subscribers' updates are resolved
  from. Each subscriber's operation runs against it, with `filter?` choosing who
  receives it.
- It fires **once the field resolved successfully**: a mutation that raised, was
  rejected by `@guard`, `@can*` or `@validator`, failed model validations, or
  returned `nil` broadcasts nothing. It runs after `@create`/`@update` saved,
  so the transaction they open has committed.
- It is **repeatable**: every occurrence triggers its own subscription, once.
- `subscription:` is the field's name in the `Subscription` type (`snake_case`
  works too). One that does not exist is a `Lighthouse::DefinitionError` when the
  schema is built.
- A field returning a **list** (`@createMany`) broadcasts the list as one root. A
  subscription field of a list type, or a `resolve_payload` that picks from it,
  handles it.
- A schema with **no subscriptions backend** reports a `Lighthouse::DefinitionError`
  saying how to install one, through `Config.on_error` (raised in a test
  environment, logged otherwise); the mutation itself has succeeded.

### Topics, trigger arguments and filtering

graphql-ruby sends an update only to the subscribers whose arguments **equal** the
arguments of the trigger: `trigger(:post_updated, { author: 1 }, post)` reaches
`postUpdated(author: 1)` and no one else. PHP Lighthouse does the opposite: the
topic is the field, every subscriber is a candidate, and `filter` decides. The
two are different trade-offs, so `Lighthouse::GraphQL::Subscription` takes
PHP Lighthouse's and lets you choose, per class:

| | `topic_by :field` (the default) | `topic_by :arguments` |
| --- | --- | --- |
| A broadcast reaches | every subscriber, narrowed by `filter?` | the subscribers whose arguments equal the trigger's |
| Trigger arguments | none needed | `self.trigger_arguments(root, context)` must rebuild them |
| Condition on the subscriber | any Ruby, using their `context` and arguments | equality only |
| Cost of a broadcast | each subscriber's operation is evaluated, then filtered | only the matching subscribers' |

Take the default when the condition is more than "the argument equals": ownership,
permissions, a list of ids, a score threshold. Take `topic_by :arguments` when
there are many subscribers and the argument identifies a small group of them (a
chat room, a document):

```ruby
module Subscriptions
  class MessagePosted < Lighthouse::GraphQL::Subscription
    topic_by :arguments

    # @broadcast triggers with these: the subscribers of `messagePosted(room: "<id>")`.
    def self.trigger_arguments(message, _context) = { room: message.room_id.to_s }
  end
end
```

A plain `GraphQL::Schema::Subscription` keeps graphql-ruby's exact matching;
define `self.trigger_arguments(root, context)` on it, so `@broadcast` knows which
to use (without it, `{}`). `self.trigger_scope(root, context)` likewise supplies
the `scope:` for a class declaring `subscription_scope` (graphql-ruby's way to give
each tenant or user their own stream).

`broadcast: true` on the backend lets graphql-ruby evaluate identical
subscriptions once. Do not combine it with a `filter?` that reads the
subscriber's `context`: they would share one evaluation.

### Queueing

A broadcast runs inside the mutation's request by default. `shouldQueue: true`, or
`Lighthouse::Config.queue_broadcasts = true` for every `@broadcast` that does not
say otherwise, enqueues an ActiveJob, `Lighthouse::GraphQL::BroadcastJob`, which
does the trigger:

```ruby
Lighthouse.configure do |config|
  config.queue_broadcasts = true
  config.broadcast_queue = :subscriptions   # default: ActiveJob's default queue
end
```

The job carries the schema's name, the subscription's name, the trigger arguments,
the scope and the root; an Active Record model is serialized with GlobalID, any
other root must be something ActiveJob can serialize. A schema built by
`get_schema` and assigned to a constant (`AppSchema = ...`) has the name; an
anonymous one raises `Lighthouse::DefinitionError` when a queued broadcast needs
it. The `activejob` gem is optional: nothing loads it unless a broadcast is queued.

## Triggering by hand

Any code can trigger a subscription, as in graphql-ruby, for what is not a
mutation:

```ruby
AppSchema.subscriptions.trigger(:post_updated, {}, post)
AppSchema.subscriptions.trigger(:message_posted, { room: room.id.to_s }, message, scope: room.tenant_id)
```

The arguments and scope are those the subscription's class would produce for its
topic (see [above](#topics-trigger-arguments-and-filtering)): none for the default
`topic_by :field`.

## Testing

`GraphQL::Subscriptions` is an interface of a handful of methods
(`write_subscription`, `read_subscription`, `delete_subscription`, `deliver`,
`execute_all`), so a spec can install a backend that keeps everything in memory:
the repository's own specs do, in `spec/support/in_memory_subscriptions.rb`.
graphql-ruby also ships `GraphQL::Testing::MockActionCable` for the real
ActionCable backend.
