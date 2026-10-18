# frozen_string_literal: true

# graphql-ruby's convention gives each kind of root field class a base
# (Resolvers::BaseResolver, ...). Handed to the schema in base_types, beside
# graphql-ruby's own base types, Lighthouse holds the classes to it.
module ResolverBasesSpec
  class BaseResolver < GraphQL::Schema::Resolver; end

  class BaseMutation < GraphQL::Schema::Mutation; end

  class BaseSubscription < GraphQL::Schema::Subscription
    include Lighthouse::GraphQL::Subscription
  end

  class Greeting < BaseResolver
    def resolve = 'hello'
  end

  class Stray < GraphQL::Schema::Resolver
    def resolve = 'stray'
  end

  class Publish < BaseMutation
    def resolve = true
  end

  class StrayMutation < GraphQL::Schema::Mutation
    def resolve = true
  end

  class StraySubscription < GraphQL::Schema::Subscription; end

  class BaseObject < GraphQL::Schema::Object; end
end

RSpec.describe 'base_types: resolver, mutation and subscription' do
  let(:bases) do
    {
      resolver: ResolverBasesSpec::BaseResolver,
      mutation: ResolverBasesSpec::BaseMutation,
      subscription: ResolverBasesSpec::BaseSubscription
    }
  end

  let(:sdl) do
    <<~GRAPHQL
      type Widget { id: ID! }
      type Query { greeting: String stray: String widget: Widget }
      type Mutation { publish: Boolean strayMutation: Boolean }
      type Subscription { widgetAdded: Widget strayAdded: Widget }
    GRAPHQL
  end

  let(:schema) { build_schema(sdl, base_types: bases) }

  before do
    stub_const('Resolvers::Greeting', ResolverBasesSpec::Greeting)
    stub_const('Resolvers::Stray', ResolverBasesSpec::Stray)
    stub_const('Mutations::Publish', ResolverBasesSpec::Publish)
    stub_const('Mutations::StrayMutation', ResolverBasesSpec::StrayMutation)
    stub_const('Subscriptions::StrayAdded', ResolverBasesSpec::StraySubscription)
  end

  it 'resolves the classes that inherit from their base' do
    expect(schema.execute('{ greeting }')['data']).to eq('greeting' => 'hello')
    expect(schema.execute('mutation { publish }')['data']).to eq('publish' => true)
  end

  it 'refuses a Query class that skips the resolver base' do
    expect { schema.execute('{ stray }') }.to raise_error(
      Lighthouse::DefinitionError,
      'ResolverBasesSpec::Stray resolves Query.stray, so it must inherit from ResolverBasesSpec::BaseResolver, ' \
      "the schema's base class for it (base_types)."
    )
  end

  it 'refuses a Mutation class that skips the mutation base' do
    expect { schema.execute('mutation { strayMutation }') }
      .to raise_error(Lighthouse::DefinitionError, /StrayMutation resolves Mutation.strayMutation, so it must inherit from ResolverBasesSpec::BaseMutation/)
  end

  it 'resolves a Subscription field with no class of its own with the subscription base' do
    expect(schema.subscription.fields['widgetAdded'].resolver).to eq(ResolverBasesSpec::BaseSubscription)
  end

  it 'refuses a Subscription class that skips the subscription base' do
    expect { schema.subscription.fields['strayAdded'].resolver }
      .to raise_error(Lighthouse::DefinitionError, /StraySubscription resolves Subscription.strayAdded, so it must inherit from ResolverBasesSpec::BaseSubscription/)
  end

  it "passes graphql-ruby's own base types on, and leaves the caller's Hash as it was" do
    base_types = bases.merge(object: ResolverBasesSpec::BaseObject)

    built = build_schema(sdl, base_types: base_types)

    expect(built.types['Widget'].superclass).to eq(ResolverBasesSpec::BaseObject)
    expect(base_types.keys).to contain_exactly(:resolver, :mutation, :subscription, :object)
  end

  it 'refuses a base that is not the graphql-ruby class of its kind' do
    expect { build_schema(sdl, base_types: { mutation: ResolverBasesSpec::BaseResolver }) }
      .to raise_error(Lighthouse::DefinitionError, /base_types\[:mutation\] must be a subclass of GraphQL::Schema::Mutation/)
  end

  it 'holds no class to a base that was not given' do
    expect(build_schema(sdl).execute('{ stray }')['data']).to eq('stray' => 'stray')
    expect(build_schema(sdl).subscription.fields['widgetAdded'].resolver).to eq(Lighthouse::GraphQL::Subscription::Default)
  end
end
