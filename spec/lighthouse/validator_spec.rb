# frozen_string_literal: true

module Validators
  # Default name for a field validator: Validators::<ParentType>::<Field>Validator.
  module Mutation
    class SignUpValidator < Dry::Validation::Contract
      option :graphql_context, optional: true

      params do
        required(:email).filled(:string)
        required(:password).filled(:string)
        optional(:password_confirmation).maybe(:string)
      end

      rule(:password_confirmation) do
        key.failure('must match password') if value && value != values[:password]
      end

      rule(:email) do
        reserved = graphql_context && graphql_context[:reserved_emails]
        key.failure('is reserved') if reserved&.include?(value)
      end
    end
  end

  # Default name for an input validator: Validators::<InputType>Validator.
  class AddressInputValidator < Dry::Validation::Contract
    params do
      required(:street).filled(:string)
      required(:zip_code).filled(:string, format?: /\A\d{5}\z/)
    end
  end

  class TagsContract < Dry::Validation::Contract
    params { required(:tags).value(:array, min_size?: 2).each(:string) }
  end

  # Any object whose call(values) returns a { key => [messages] } Hash works too.
  class NoSpam
    def call(values)
      values[:title].to_s.include?('spam') ? { title: ['looks like spam'] } : {}
    end
  end
end

RSpec.describe '@validator' do
  let(:sdl) do
    <<~GRAPHQL
      type Query {
        tagged(tags: [String!]!): Boolean @validator(class: "TagsContract") @field(resolver: "ValidatorSpecOk")
      }

      type Mutation {
        signUp(email: String!, password: String!, passwordConfirmation: String): Boolean
          @validator @field(resolver: "ValidatorSpecOk")
        ship(to: AddressInput!, billing: BillingInput): Boolean @field(resolver: "ValidatorSpecOk")
        shipMany(to: [AddressInput!]!): Boolean @field(resolver: "ValidatorSpecOk")
        createPost(title: String): Post @create @validator(class: "NoSpam")
      }

      input AddressInput @validator {
        street: String
        zipCode: String
      }

      input BillingInput {
        address: AddressInput
      }

      type Post {
        id: ID!
        title: String
      }
    GRAPHQL
  end

  let(:schema) { build_schema(sdl) }

  before do
    stub_const('ValidatorSpecOk', Class.new { def self.call(*) = true })
  end

  def run(query, context = {})
    schema.execute(query, context: context).to_h
  end

  def validation(result)
    result.dig('errors', 0, 'extensions', 'validation')
  end

  describe 'on a field' do
    it 'lets valid arguments through to the resolver' do
      result = run('mutation { signUp(email: "a@b.c", password: "pw", passwordConfirmation: "pw") }')

      expect(result).to eq('data' => { 'signUp' => true })
    end

    it 'rejects invalid ones before resolving, keyed by GraphQL argument name' do
      result = run('mutation { signUp(email: "a@b.c", password: "pw", passwordConfirmation: "other") }')

      expect(result['data']).to eq('signUp' => nil)
      expect(result['errors'].first['message']).to eq('Validation failed for the field [signUp].')
      expect(validation(result)).to eq('passwordConfirmation' => ['must match password'])
    end

    it 'hands the GraphQL context to a contract that declares option :graphql_context' do
      result = run('mutation { signUp(email: "root@x.y", password: "pw") }', reserved_emails: ['root@x.y'])

      expect(validation(result)).to eq('email' => ['is reserved'])
    end

    it 'takes an explicit class:, looked up in the validators namespace' do
      expect(validation(run('{ tagged(tags: ["one"]) }'))).to eq('tags' => ['size cannot be less than 2'])
      expect(run('{ tagged(tags: ["one", "two"]) }')).to eq('data' => { 'tagged' => true })
    end

    it 'accepts any callable returning an errors Hash, and runs before @create' do
      result = run('mutation { createPost(title: "buy spam") { id } }')

      expect(validation(result)).to eq('title' => ['looks like spam'])
      expect(Post.count).to eq(0)
    end

    it "still reports the model's own validations afterwards" do
      expect(validation(run('mutation { createPost(title: "") { id } }'))).to eq('title' => ["Title can't be blank"])
    end
  end

  describe 'on an input type' do
    it 'validates the input wherever a field takes it, without a directive on the field' do
      result = run('mutation { ship(to: { street: "Main St", zipCode: "123" }) }')

      expect(validation(result)).to eq('to.zipCode' => ['is in invalid format'])
    end

    it 'validates it nested inside another input' do
      result = run('mutation { ship(to: { street: "a", zipCode: "12345" }, billing: { address: { zipCode: "1" } }) }')

      expect(validation(result)).to eq('billing.address.street' => ['is missing'],
                                       'billing.address.zipCode' => ['is in invalid format'])
    end

    it 'validates each item of a list, keyed by index' do
      result = run('mutation { shipMany(to: [{ street: "a", zipCode: "12345" }, { street: "", zipCode: "12345" }]) }')

      expect(validation(result)).to eq('to.1.street' => ['must be filled'])
    end

    it 'passes valid input' do
      expect(run('mutation { ship(to: { street: "a", zipCode: "12345" }) }')).to eq('data' => { 'ship' => true })
    end
  end

  it 'fails loudly when the validator class does not exist' do
    broken = build_schema(<<~GRAPHQL)
      type Query { a(x: Int): Int @validator(class: "Nope") @field(resolver: "ValidatorSpecOk") }
    GRAPHQL

    expect { broken.execute('{ a(x: 1) }') }.to raise_error(Lighthouse::DefinitionError, /no validator class Nope/)
  end
end
