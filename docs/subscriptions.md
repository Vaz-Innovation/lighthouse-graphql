# Subscriptions

A subscription lets a client ask for a stream of updates: it sends a `subscription`
operation once, and the server sends a result each time something it cares about
happens. Lighthouse builds on [graphql-ruby's subscriptions](https://graphql-ruby.org/subscriptions/overview.html)
and keeps the shape of [PHP Lighthouse's](https://lighthouse-php.com/master/subscriptions/getting-started.html):

- a `Subscription` field is declared in the SDL, and **resolves by convention** to a class;
- that class inherits from `Subscriptions::BaseSubscription`, a graphql-ruby
  [`GraphQL::Schema::Subscription`](https://graphql-ruby.org/subscriptions/subscription_classes.html),
  as a `Query` field's class is a `Resolvers::BaseResolver` and a mutation's a
  `Mutations::BaseMutation` (see [resolvers.md](resolvers.md#base-classes)). The base
  includes [Lighthouse's concern](#the-subscription-concern): PHP
  Lighthouse's model, one topic per field and a `filter?`;
- a mutation announces what it did with [`@broadcast`](#broadcast-from-a-mutation).

```graphql
type Subscription {
  postUpdated: Post
}

type Mutation {
  updatePost(id: ID!, title: String): Post! @update @broadcast(subscription: "postUpdated")
}
```

```ruby
# app/graphql/subscriptions/post_updated.rb  (rails generate lighthouse:subscription PostUpdated)
class Subscriptions::PostUpdated < Subscriptions::BaseSubscription
  # For each broadcast: skip the subscribers who may not see this post.
  def filter?(post, **)
    post.published? || post.author == context[:current_user]
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
    transmit({ result: result.to_h, more: result.subscription? })
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
GlobalID. A Rails app that loads ActiveJob has that; one that picks its railties
(an API-only `config/application.rb`) needs `require 'global_id/railtie'`, or the
subscribers would receive the model's `inspect` string.

## Defining subscription fields

A field of the `Subscription` type needs nothing but its SDL, and then
**every broadcast reaches every subscriber, unchanged**: `@broadcast` hands the
mutation's result to the subscription, which resolves the field with it.

```graphql
type Subscription {
  postCreated: Post
}
```

For anything more, write the class. (A field with no class of its own resolves with
the schema's `base_types[:subscription]`, else with a built-in class that includes
the concern: one topic for the field, no `filter?`.) `Subscription.postUpdated` resolves to
`Subscriptions::PostUpdated`, looked up in `Config.namespaces[:subscriptions]`
(default `['Subscriptions']`) each time it is needed, so code reloading works.
`rails generate lighthouse:subscription PostUpdated` writes it. It inherits from
`Subscriptions::BaseSubscription`, a `GraphQL::Schema::Subscription`: anything you
know from graphql-ruby applies.

Like a query or a mutation class, it declares neither the arguments nor the return
type: the SDL does. The field's arguments arrive as `snake_case` keywords.

### The lifecycle

graphql-ruby calls the class twice in a subscription's life: once for the
**subscription request** (the client's `subscription { ... }`), and then once for
**each update** (`@broadcast`, or `schema.subscriptions.trigger`). All hooks are
optional. These are graphql-ruby's own; the concern `BaseSubscription` includes
implements `authorized?` and `update` with PHP Lighthouse's hooks
([below](#the-subscription-concern)), and a class that defines them itself
keeps graphql-ruby's behavior.

| Hook | Called | Default |
| --- | --- | --- |
| `authorized?(**args)` | for the request **and** for every update | `true` |
| `subscribe(**args)` | for the request: its return value answers the client at once | `:no_response`: nothing yet |
| `update(**args)` | for each update: its return value is what the field resolves to | `object`, the broadcast root |
| `unsubscribe` | call it to end the subscription from the server | |
| `self.subscription_scope` | declare it to give each tenant or user their own stream | none |
| `self.topic_for(arguments:, field:, scope:)` | the stream a subscription joins and a trigger addresses | the field, its scope and its arguments |

- **`args`** are the arguments the client *subscribed* with, in `snake_case`.
  `object` is the broadcast root in `update`, and `context` is the *subscriber's*:
  graphql-ruby stores it with the subscription and replays it for each update, so
  `context[:current_user]` is whoever subscribed.
- **`update`** returns `NO_UPDATE` (`GraphQL::Schema::Subscription::NO_UPDATE`) to
  skip this subscriber for this broadcast, or another value to send it instead of
  `object`.
- **`subscribe`** is where to send an initial payload (the current state, say);
  return `:no_response`, or leave it out, to send nothing until the first update.
- **`authorized?`** runs again for each update, with the subscriber's stored
  context. Raising a `GraphQL::ExecutionError` refuses the request and tells the
  client why; nothing is registered. Returning `false` refuses it silently: the
  field comes back `null`, with no error.

```ruby
class Subscriptions::OrderShipped < Subscriptions::BaseSubscription
  def authorized?(**)
    raise GraphQL::ExecutionError, 'Sign in to follow your orders.' unless context[:current_user]

    true
  end

  def update(**)
    object.user_id == context[:current_user].id ? object : NO_UPDATE
  end
end
```

If you know PHP Lighthouse's `GraphQLSubscription`, this is where its methods went:

| PHP Lighthouse | graphql-ruby |
| --- | --- |
| `authorize(Subscriber, Request): bool` | `authorized?`, which also runs for each update (check `context.query.subscription_update?` to tell them apart) |
| `filter(Subscriber, $root): bool` | `update` returning `NO_UPDATE` |
| `resolve($root, $args, $context, $info)` | `update`'s return value |
| `encodeTopic` / `decodeTopic` | `self.topic_for(arguments:, field:, scope:)` |
| the subscriber's `$args` | the keywords of `subscribe` and `update` |
| `Subscription::broadcast($name, $root)` | `@broadcast`, or `schema.subscriptions.trigger` |

One real difference is the **topic**. PHP Lighthouse puts every subscriber of a
field on one topic and `filter` decides who is updated. graphql-ruby's default
topic includes the arguments, so a trigger reaches only the subscribers whose
arguments *equal* its own. The concern in `BaseSubscription` takes PHP Lighthouse's
topic; a class that keeps graphql-ruby's gives `@broadcast` its `trigger_arguments`.
See [below](#topics-trigger-arguments-and-filtering).

## The subscription concern

`Lighthouse::GraphQL::Subscription` is PHP Lighthouse's model: one topic per field,
`filter?` to narrow it and `resolve_payload` for the result. It is included once, in
the base every subscription inherits from, as graphql-ruby's convention puts what
all classes of a kind share in their base:

```ruby
# app/graphql/subscriptions/base_subscription.rb  (rails generate lighthouse:install)
module Subscriptions
  class BaseSubscription < GraphQL::Schema::Subscription
    include Lighthouse::GraphQL::Subscription
  end
end
```

A subscription is still a plain `GraphQL::Schema::Subscription`, and declares its
arguments as one would in graphql-ruby (or leaves them to the SDL).
`rails generate lighthouse:subscription PostUpdated` writes one with the hooks:

```ruby
class Subscriptions::PostUpdated < Subscriptions::BaseSubscription
  def filter?(post, author: nil)
    author.nil? || post.author_id.to_s == author.to_s
  end
end
```

The concern maps the hooks of `GraphQLSubscription` onto graphql-ruby's. All are
optional.

| PHP Lighthouse | Concern | Maps onto | Default |
| --- | --- | --- | --- |
| `authorize(Subscriber, Request): bool` | `authorize?(**args)` | `authorized?`, on the subscription request only | `true` |
| `filter(Subscriber, $root): bool` | `filter?(root, **args)` | `update` returns `NO_UPDATE` when it is false | `true` |
| `resolve($root, $args, $context, $info)` | `resolve_payload(root, **args)` | the value `update` returns | `root` |
| `encodeTopic` / `decodeTopic` | `self.topic_for(arguments:, field:, scope:)` | graphql-ruby's topic | the field and its scope |

- `authorize?` returning false refuses the subscription: the client gets
  `Unauthorized subscription request.` and nothing is registered. Raise a
  `GraphQL::ExecutionError` to say more. Unlike `authorized?`, it is not called again for the updates.
- `filter?` is where a subscriber is turned down for one broadcast.
- The concern also adds the class methods `topic_by`, `topic_for`,
  `trigger_arguments` and `trigger_scope`, which `topic_by` and the
  [broadcast section](#topics-trigger-arguments-and-filtering) explain.
- Including it in a class that is not a `GraphQL::Schema::Subscription` raises a
  `Lighthouse::DefinitionError`.
- To keep graphql-ruby's model for every subscription, leave the `include` out of
  `BaseSubscription`; the generator then writes classes with `authorized?` and
  `update` instead.
- **Precedence.** The concern sits between your class and
  `GraphQL::Schema::Subscription` (it is in the base), so what the class defines
  itself wins. A class
  with its own `update` (or `authorized?`) is called instead of the concern's, and
  its `filter?`, `resolve_payload` (or `authorize?`) are not, unless it calls
  `super`. `subscribe`, `unsubscribe`, `subscription_scope` and `ready?` are
  untouched, and combine freely with the hooks.

```ruby
class Subscriptions::OrderShipped < Subscriptions::BaseSubscription
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
```

Its topic is the **field** (and its scope), not its arguments: a broadcast reaches
every subscriber, and `filter?` decides. `topic_by :arguments` (inherited by
subclasses) turns graphql-ruby's exact matching back on; see below.

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
`::` is used as it is. A class that does not exist, is not a
`GraphQL::Schema::Subscription`, or does not inherit from the schema's
`base_types[:subscription]` raises `Lighthouse::DefinitionError`.
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
  from (`object` in `update`). Each subscriber's operation runs against it, and
  `update` (or `filter?`) can turn a subscriber down.
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
`postUpdated(author: 1)` and no one else. `@broadcast` has to know what to trigger
with, so it asks the class: `self.trigger_arguments(root, context)` returns the
arguments (a Hash, `{}` by default) for the `root` a mutation returned, and
`self.trigger_scope(root, context)` the `scope:` for a class declaring
`subscription_scope` (graphql-ruby's way to give each tenant or user their own
stream).

When the topic includes the arguments (a class with `topic_by :arguments`, or under
a base that does not include the concern):

- **A field without arguments works out of the box.** Every subscriber's arguments
  are `{}`, and so is the trigger's.
- **A field with arguments needs `trigger_arguments`**, returning the value of every
  argument that identifies the group of subscribers:

  ```graphql
  type Subscription {
    messagePosted(room: ID!): Message
  }
  ```

  ```ruby
  class Subscriptions::MessagePosted < Subscriptions::BaseSubscription
    topic_by :arguments

    # The subscribers of `messagePosted(room: "<id>")`.
    def self.trigger_arguments(message, _context) = { room: message.room_id.to_s }
  end
  ```

- **Arguments and no `trigger_arguments` is a misconfiguration**, and it fails
  silently in graphql-ruby: a trigger of `{}` equals no subscriber's arguments, so
  nobody is ever updated. Lighthouse reports it the first time such a field is
  broadcast, with the field, the class and the arguments, as a
  `Lighthouse::DefinitionError` through `Config.on_error` (raised in a test
  environment, logged otherwise), and triggers nothing. It is reported when the
  broadcast happens rather than when the schema is built, because the class is only
  looked up then (so that code reloading works), and only when an argument is
  **required**: that is certain to reach nobody. A field whose arguments are all
  optional is not reported, since its argument-less subscribers do match `{}`; only
  those subscribers are updated, so give such a class a `trigger_arguments` too if
  subscribers pass the argument.
- **To have one trigger reach subscribers with different arguments** (the argument
  is a filter, not an identity) without the concern, give the class one topic per
  field, as graphql-ruby documents, and let `update` return `NO_UPDATE`:

  ```ruby
  class Subscriptions::PostPublished < Subscriptions::BaseSubscription # a base without the concern
    def self.topic_for(field:, scope:, **)
      GraphQL::Subscriptions::Serialize.dump_recursive([scope, field.graphql_name])
    end

    def update(author_id: nil)
      author_id.nil? || object.author_id.to_s == author_id.to_s ? object : NO_UPDATE
    end
  end
  ```

PHP Lighthouse works this way by default: the topic is the field, every subscriber
is a candidate, and `filter` decides. The `Lighthouse::GraphQL::Subscription`
concern does the same and lets you choose, per class:

| | `topic_by :field` (the default) | `topic_by :arguments` |
| --- | --- | --- |
| A broadcast reaches | every subscriber, narrowed by `filter?` | the subscribers whose arguments equal the trigger's |
| Trigger arguments | none needed | `self.trigger_arguments(root, context)` must rebuild them |
| Condition on the subscriber | any Ruby, using their `context` and arguments | equality only |
| Cost of a broadcast | each subscriber's operation is evaluated, then filtered | only the matching subscribers' |

Take the field-wide topic when the condition is more than "the argument equals":
ownership, permissions, a list of ids, a score threshold. Take exact arguments
when there are many subscribers and the argument identifies a small group of them
(a chat room, a document). A `topic_by :arguments` class needs `trigger_arguments`
for a field with required arguments like a plain one, and is reported the same way.
(The concern's own `trigger_arguments` returns `{}`; define yours on the class.)

`broadcast: true` on the backend lets graphql-ruby evaluate identical
subscriptions once. Do not combine it with an `update` or `filter?` that reads the
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
topic (see [above](#topics-trigger-arguments-and-filtering)): none for a field
without arguments, or for the default `topic_by :field`.

## Testing

`GraphQL::Subscriptions` is an interface of a handful of methods
(`write_subscription`, `read_subscription`, `delete_subscription`, `deliver`,
`execute_all`), so a spec can install a backend that keeps everything in memory:
the repository's own specs do, in `spec/support/in_memory_subscriptions.rb`.
graphql-ruby also ships `GraphQL::Testing::MockActionCable` for the real
ActionCable backend.

The repository's `example/` app is a complete setup: subscription classes under
`Subscriptions::BaseSubscription`,
`GraphqlChannel`, `ApplicationCable::Connection` with token authentication, and
specs that drive a mutation through `POST /graphql` and watch the update arrive on
an ActionCable subscriber (`example/spec/subscriptions/delivery_spec.rb`).
