# Custom Directives

Adding a directive to Lighthouse is "write one class and register it." There are
no edits to Lighthouse internals — the generator discovers behavior through a set
of **contracts** (marker modules) and a **registry**.

## The architecture

Lighthouse builds a schema in two phases, mirroring PHP Lighthouse's
manipulator/resolver split:

1. **Manipulation phase** (before the schema is built) — directives that need to
   reshape the SDL/AST run here: `@paginate` injecting a Paginator type,
   `@whereConditions` generating input and enum types, etc.
2. **Resolution phase** (after `GraphQL::Schema.from_definition`) — directives
   attach runtime behavior: resolving data, wrapping a resolver, or composing a
   query constraint.

A `Lighthouse::DirectiveRegistry` maps directive names to the classes that
implement them. The generator iterates the registry rather than a hardcoded
dispatch table.

## The contracts

Include the marker module(s) your directive fulfils:

| Contract | Role | Key method |
| --- | --- | --- |
| `Contracts::FieldResolver` | provide a field's resolver | `#define_resolver(type)` (or `#resolve_field`) |
| `Contracts::FieldMiddleware` | wrap an existing resolver (e.g. `@auth`) | `#wrap_resolver(next)` |
| `Contracts::FieldManipulator` | reshape the schema for a field | `manipulate_field_definition(...)` |
| `Contracts::ArgManipulator` | reshape the schema for an argument | `manipulate_argument_definition(...)` |
| `Contracts::ArgBuilder` | compose a query constraint from an argument | `#handle_builder(relation, value)` |

A directive class also answers two class-level questions: its name and its SDL
definition.

```ruby
def self.directive_name = 'upcase'
def self.definition = 'directive @upcase on FIELD_DEFINITION'
```

If the definition refers to types of its own (an enum argument, say), return
them from `def self.type_definitions = { 'Mode' => 'enum Mode { A B }' }`.

Lighthouse injects that `definition` into the schema automatically, so apps never
hand-declare your directive, and `bin/rails lighthouse:ide_helper` writes it out
for the IDE (see [IDE support](getting-started.md#ide-support)).

## Example 1 — an argument filter

Argument-builder directives are the simplest. Suppose you want `@startsWith`:

```ruby
module App
  module Graphql
    module Directives
      class StartsWith < Lighthouse::GraphQL::Directives::Arguments::Base
        def self.directive_name = 'startsWith'
        def self.definition = 'directive @startsWith(key: String) on ARGUMENT_DEFINITION'

        def handle_builder(relation, value)
          return relation if value.nil?

          relation.where(arel_column(relation).matches("#{value}%"))
        end
      end
    end
  end
end
```

`Arguments::Base` gives you `column` (the `key:` override or snake_cased arg name)
and `arel_column(relation)`.

## Example 2 — a field resolver

A field-resolver directive attaches a resolver to a field. The simplest path is to
subclass the base resolver and implement `define_resolver`:

```ruby
module App
  module Graphql
    module Directives
      class UpcaseDirective < Lighthouse::GraphQL::DirectiveResolvers::BaseDirectiveResolver
        def self.directive_name = 'upcase'
        def self.definition = 'directive @upcase on FIELD_DEFINITION'

        def define_resolver(target_type)
          name = @field_def.name
          target_type.define_singleton_method("resolve_field_#{name}") do |obj, _args, _ctx|
            value = obj.public_send(Lighthouse::Support::Naming.attribute(name))
            value&.upcase
          end
        end
      end
    end
  end
end
```

## Registering

Register your directive once, from your Lighthouse initializer:

```ruby
# config/initializers/lighthouse.rb
Lighthouse::DirectiveRegistry.register(App::Graphql::Directives::StartsWith)
Lighthouse::DirectiveRegistry.register(App::Graphql::Directives::UpcaseDirective)
```

It is now usable in your SDL — no other changes:

```graphql
type Query {
  users(name: String @startsWith): [User!]! @all
}

type User {
  shoutName: String @upcase @rename(attribute: "name")
}
```

## Naming helper

Whenever you map a GraphQL name to a database column or model attribute, route
through `Lighthouse::Support::Naming` so your directive honors the same
camelCase→snake_case rule as the rest of the library:

```ruby
Lighthouse::Support::Naming.attribute('customAttributes') # => "custom_attributes"
Lighthouse::Support::Naming.column('CREATED_AT')          # => "created_at"
```
