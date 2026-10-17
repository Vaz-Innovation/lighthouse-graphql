# Validation

Rails puts validation in the model, and so does Lighthouse: the
[mutation directives](mutations.md) save through ActiveRecord, so `validates`
rules apply with no configuration. Not every rule belongs to a model, though:
a password confirmation, a rule across two arguments, the arguments of a query, or
input that never reaches a model at all. For those, `@validator` runs a contract
class before the field resolves.

Both report errors the same way, in PHP Lighthouse's format: messages keyed by
argument path under `extensions.validation`.

```json
{
  "data": { "signUp": null },
  "errors": [{
    "message": "Validation failed for the field [signUp].",
    "extensions": { "validation": { "passwordConfirmation": ["must match password"] } }
  }]
}
```

## Model validations

Nothing to do. A failed `save` in `@create`, `@update`, `@createMany` or
`@updateMany` reports the model's `full_message`s, keyed by the argument each
attribute came from (see [mutations.md](mutations.md#validation-errors)).

## `@validator`

```graphql
directive @validator(class: String) on FIELD_DEFINITION | INPUT_OBJECT
```

### On a field

The contract receives all of the field's arguments:

```graphql
type Mutation {
  signUp(email: String!, password: String!, passwordConfirmation: String): User @validator
}
```

```ruby
# app/graphql/validators/mutation/sign_up_validator.rb
module Validators
  module Mutation
    class SignUpValidator < Dry::Validation::Contract
      params do
        required(:email).filled(:string)
        required(:password).filled(:string, min_size?: 12)
        optional(:password_confirmation).maybe(:string)
      end

      rule(:password_confirmation) do
        key.failure('must match password') if value && value != values[:password]
      end
    end
  end
end
```

The class defaults to `Validators::<ParentType>::<FieldName>Validator`. Name
another with `@validator(class: "SignUpRules")`; it is looked up in the validators
namespace.

### On an input type

The contract receives that input's values. It runs **wherever the type is used**:
as an argument, nested inside another input, or as each item of a list. The
fields that take the input need no directive.

```graphql
input AddressInput @validator {
  street: String
  zipCode: String
}

type Mutation {
  ship(to: AddressInput!, billing: BillingInput): Shipment
  shipMany(to: [AddressInput!]!): [Shipment!]!
}
```

The class defaults to `Validators::<InputType>Validator`, here
`Validators::AddressInputValidator`. Errors are prefixed with the path to the
input: `to.zipCode`, `billing.address.street`, `to.1.street`.

### Contracts

A contract is a [Dry::Validation](https://dry-rb.org/gems/dry-validation/)
contract:

- Values arrive with `snake_case` symbol keys, and the error keys are mapped back
  to the GraphQL argument names.
- Declare `option :graphql_context, optional: true` to read the GraphQL context in
  rules (e.g. `graphql_context[:current_user]`).
- `dry-validation` is an optional dependency. Add it to your Gemfile to use these
  contracts.

Any other object works if its `call(values)` returns a Dry-style result, or a
`{ key => [messages] }` Hash (empty when valid):

```ruby
module Validators
  class NoSpam
    def call(values)
      values[:title].to_s.include?('spam') ? { title: ['looks like spam'] } : {}
    end
  end
end
```

A missing class raises `Lighthouse::DefinitionError`. Lighthouse never silently
skips validation.

### Order

Validation runs after authentication and authorization (`@guard`, `@can*`), so
anonymous clients cannot probe your rules, and before `@cache` and the resolver.
All contracts on a field run, and their errors are reported together.

Generate a contract with `bin/rails generate lighthouse:validator AddressInput`.

## Why not `@rules`?

PHP Lighthouse's `@rules(apply: ["email", "max:280"])` embeds Laravel's
string-based rule language in the schema. Rails has no equivalent to port: its
validations live in models, and Dry contracts express the rest as Ruby with
proper types. So Lighthouse for Rails supports those two, and does not invent a
third rule syntax.
