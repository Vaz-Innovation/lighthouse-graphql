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

  # Evaluate generated files inside an anonymous module, in order (a base class
  # before the class inheriting from it), so the constants they define never
  # leak into Object, and return the class `constant` names.
  def load_generated(*paths, constant)
    sandbox = Module.new
    paths.each do |path|
      file = File.join(root, path)
      sandbox.module_eval(File.read(file), file)
    end
    sandbox.const_get(constant)
  end

  def read(path) = File.read(File.join(root, path))

  def write(path, content)
    FileUtils.mkdir_p(File.dirname(File.join(root, path)))
    File.write(File.join(root, path), content)
  end

  # What graphql-ruby's graphql:install writes, which lighthouse:install runs.
  def write_graphql_ruby_bases
    write('app/graphql/resolvers/base_resolver.rb', "module Resolvers\n  class BaseResolver < GraphQL::Schema::Resolver\n  end\nend\n")
    write('app/graphql/mutations/base_mutation.rb', "module Mutations\n  class BaseMutation < GraphQL::Schema::Mutation\n  end\nend\n")
  end

  describe 'lighthouse:query' do
    it 'generates a resolver in app/graphql/resolvers that inherits from Resolvers::BaseResolver' do
      write_graphql_ruby_bases
      output = generate(Lighthouse::Generators::QueryGenerator, 'GeneratedLatestPosts')

      klass = load_generated('app/graphql/resolvers/base_resolver.rb', 'app/graphql/resolvers/generated_latest_posts.rb',
                             'Resolvers::GeneratedLatestPosts')
      expect(klass.superclass.name).to end_with('Resolvers::BaseResolver')
      expect(klass.superclass.superclass).to eq(GraphQL::Schema::Resolver)
      expect(output).to include('Query.generatedLatestPosts resolves to Resolvers::GeneratedLatestPosts')
    end

    it 'says how to get the base graphql-ruby writes when it is missing, and writes no copy of it' do
      output = generate(Lighthouse::Generators::QueryGenerator, 'Orphan')

      expect(output).to include('app/graphql/resolvers/base_resolver.rb: graphql-ruby writes it', 'lighthouse:install')
      expect(File).not_to exist(File.join(root, 'app/graphql/resolvers/base_resolver.rb'))
      expect(read('app/graphql/resolvers/orphan.rb')).to include('class Orphan < BaseResolver')
    end

    it 'keeps an existing base class, such as the one graphql-ruby\'s graphql:install wrote' do
      mine = "module Resolvers\n  class BaseResolver < GraphQL::Schema::Resolver\n    # mine\n  end\nend\n"
      write('app/graphql/resolvers/base_resolver.rb', mine)

      generate(Lighthouse::Generators::QueryGenerator, 'Feed')

      expect(read('app/graphql/resolvers/base_resolver.rb')).to eq(mine)
      expect(read('app/graphql/resolvers/feed.rb')).to include('class Feed < BaseResolver')
    end
  end

  it 'generates a mutation in app/graphql/mutations that inherits from Mutations::BaseMutation, nesting modules for a namespaced name' do
    write_graphql_ruby_bases
    generate(Lighthouse::Generators::MutationGenerator, 'Blog::GeneratedPublish')

    klass = load_generated('app/graphql/mutations/base_mutation.rb', 'app/graphql/mutations/blog/generated_publish.rb',
                           'Mutations::Blog::GeneratedPublish')
    expect(klass.superclass.name).to end_with('Mutations::BaseMutation')
    expect(klass.superclass.superclass).to eq(GraphQL::Schema::Mutation)
  end

  describe 'lighthouse:subscription' do
    let(:base) { 'app/graphql/subscriptions/base_subscription.rb' }

    it 'generates a subscription under a Subscriptions::BaseSubscription that includes the concern, with its hooks' do
      output = generate(Lighthouse::Generators::SubscriptionGenerator, 'GeneratedHooked')

      klass = load_generated(base, 'app/graphql/subscriptions/generated_hooked.rb', 'Subscriptions::GeneratedHooked')
      expect(klass.superclass.name).to end_with('Subscriptions::BaseSubscription')
      expect(klass.superclass.superclass).to eq(GraphQL::Schema::Subscription)
      expect(klass).to include(Lighthouse::GraphQL::Subscription)
      expect(klass.instance_methods(false)).to contain_exactly(:authorize?, :filter?, :resolve_payload)
      expect(output).to include('Subscription.generatedHooked resolves to Subscriptions::GeneratedHooked')
    end

    it "gives graphql-ruby's authorized? and trigger_arguments under a base without the concern" do
      write(base, "module Subscriptions\n  class BaseSubscription < GraphQL::Schema::Subscription\n  end\nend\n")

      generate(Lighthouse::Generators::SubscriptionGenerator, 'GeneratedPostUpdated')

      source = read('app/graphql/subscriptions/generated_post_updated.rb')
      klass = load_generated(base, 'app/graphql/subscriptions/generated_post_updated.rb', 'Subscriptions::GeneratedPostUpdated')
      expect(klass).not_to include(Lighthouse::GraphQL::Subscription)
      expect(klass.instance_methods(false)).to contain_exactly(:authorized?)
      expect(klass.trigger_arguments(Object.new, nil)).to eq({})
      expect(source).to include('# def subscribe(**args)', '# def update(**args)', 'NO_UPDATE')
    end
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

  it 'follows Config.namespaces, or --namespace, expecting the base class in the same namespace' do
    Lighthouse.configure { |c| c.namespaces = { queries: ['Api::Queries'] } }
    output = generate(Lighthouse::Generators::QueryGenerator, 'Feed')
    generate(Lighthouse::Generators::BuilderGenerator, 'Scoped', '--namespace=Scopes')

    feed = read('app/graphql/api/queries/feed.rb').sub("# frozen_string_literal: true\n\n", '')
    expect(feed).to match(/\Amodule Api\n  module Queries\n.*    class Feed < BaseResolver/m)
    expect(output).to include('app/graphql/api/queries/base_resolver.rb: graphql-ruby writes it', 'Api::Queries::BaseResolver yourself')
    expect(File).to exist(File.join(root, 'app/graphql/scopes/scoped.rb'))
    expect(Dir[File.join(root, 'app/graphql/scopes/base_*')]).to be_empty
  end
end
