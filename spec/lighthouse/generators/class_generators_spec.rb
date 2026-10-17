# frozen_string_literal: true

require 'tmpdir'
require 'generators/lighthouse/query_generator'
require 'generators/lighthouse/mutation_generator'
require 'generators/lighthouse/builder_generator'
require 'generators/lighthouse/validator_generator'
require 'generators/lighthouse/subscription_generator'

RSpec.describe 'lighthouse:query, :mutation, :subscription, :builder and :validator generators' do
  let(:root) { Dir.mktmpdir }

  after { FileUtils.remove_entry(root) }

  def generate(generator, *args)
    original = $stdout
    $stdout = StringIO.new
    generator.start(args, destination_root: root)
    $stdout.string
  ensure
    $stdout = original
  end

  # Evaluate a generated file inside an anonymous module, so the constants it
  # defines never leak into Object, and return the class it defines.
  def load_generated(path, constant)
    file = File.join(root, path)
    sandbox = Module.new
    sandbox.module_eval(File.read(file), file)
    sandbox.const_get(constant)
  end

  it 'generates a GraphQL::Schema::Resolver in app/graphql/queries' do
    output = generate(Lighthouse::Generators::QueryGenerator, 'GeneratedLatestPosts')

    klass = load_generated('app/graphql/queries/generated_latest_posts.rb', 'Queries::GeneratedLatestPosts')
    expect(klass.superclass).to eq(GraphQL::Schema::Resolver)
    expect(output).to include('Query.generatedLatestPosts resolves to Queries::GeneratedLatestPosts')
  end

  it 'generates a GraphQL::Schema::Mutation in app/graphql/mutations, nesting modules for a namespaced name' do
    generate(Lighthouse::Generators::MutationGenerator, 'Blog::GeneratedPublish')

    klass = load_generated('app/graphql/mutations/blog/generated_publish.rb', 'Mutations::Blog::GeneratedPublish')
    expect(klass.superclass).to eq(GraphQL::Schema::Mutation)
  end

  it 'generates a GraphQL::Schema::Subscription in app/graphql/subscriptions with authorized? and trigger_arguments' do
    output = generate(Lighthouse::Generators::SubscriptionGenerator, 'GeneratedPostUpdated')

    source = File.read(File.join(root, 'app/graphql/subscriptions/generated_post_updated.rb'))
    klass = load_generated('app/graphql/subscriptions/generated_post_updated.rb', 'Subscriptions::GeneratedPostUpdated')
    expect(klass.superclass).to eq(GraphQL::Schema::Subscription)
    expect(klass.instance_methods(false)).to contain_exactly(:authorized?)
    expect(klass.trigger_arguments(Object.new, nil)).to eq({})
    expect(source).to include('# def subscribe(**args)', '# def update(**args)', 'NO_UPDATE')
    expect(output).to include('Subscription.generatedPostUpdated resolves to Subscriptions::GeneratedPostUpdated')
  end

  it 'includes Lighthouse::GraphQL::Subscription, with its hooks, given --lighthouse' do
    output = generate(Lighthouse::Generators::SubscriptionGenerator, 'GeneratedHooked', '--lighthouse')

    klass = load_generated('app/graphql/subscriptions/generated_hooked.rb', 'Subscriptions::GeneratedHooked')
    expect(klass.superclass).to eq(GraphQL::Schema::Subscription)
    expect(klass).to include(Lighthouse::GraphQL::Subscription)
    expect(klass.instance_methods(false)).to contain_exactly(:authorize?, :filter?, :resolve_payload)
    expect(output).to include('Subscription.generatedHooked resolves to Subscriptions::GeneratedHooked')
  end

  it 'generates a builder in app/graphql/builders that returns the relation it gets' do
    generate(Lighthouse::Generators::BuilderGenerator, 'GeneratedPublished')

    klass = load_generated('app/graphql/builders/generated_published.rb', 'Builders::GeneratedPublished')
    expect(klass.call(Post.all, {}, nil)).to eq(Post.all)
  end

  it 'generates a Dry::Validation::Contract in app/graphql/validators, appending Validator' do
    generate(Lighthouse::Generators::ValidatorGenerator, 'GeneratedPostInput')

    klass = load_generated('app/graphql/validators/generated_post_input_validator.rb',
                           'Validators::GeneratedPostInputValidator')
    expect(klass.superclass).to eq(Dry::Validation::Contract)
    expect(klass.new.call({})).to be_success
  end

  it 'follows Config.namespaces, or --namespace' do
    Lighthouse.configure { |c| c.namespaces = { queries: ['Api::Queries'] } }
    generate(Lighthouse::Generators::QueryGenerator, 'Feed')
    generate(Lighthouse::Generators::BuilderGenerator, 'Scoped', '--namespace=Scopes')

    feed = File.read(File.join(root, 'app/graphql/api/queries/feed.rb')).sub("# frozen_string_literal: true\n\n", '')
    expect(feed).to match(/\Amodule Api\n  module Queries\n.*    class Feed < GraphQL::Schema::Resolver/m)
    expect(File).to exist(File.join(root, 'app/graphql/scopes/scoped.rb'))
  end
end
