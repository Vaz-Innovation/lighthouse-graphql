# frozen_string_literal: true

require 'tmpdir'
require 'generators/lighthouse/query_generator'
require 'generators/lighthouse/mutation_generator'
require 'generators/lighthouse/builder_generator'
require 'generators/lighthouse/validator_generator'

RSpec.describe 'lighthouse:query, :mutation, :builder and :validator generators' do
  around do |example|
    Dir.mktmpdir do |dir|
      @root = dir
      example.run
    end
  end

  def generate(generator, *args)
    original, $stdout = $stdout, StringIO.new
    generator.start(args, destination_root: @root)
    $stdout.string
  ensure
    $stdout = original
  end

  # Load a generated file and return the class it defines; removes it afterwards.
  def load_generated(path, constant)
    load File.join(@root, path)
    @loaded = constant
    Object.const_get(constant)
  end

  after do
    next unless @loaded

    *parents, name = @loaded.split('::')
    parents.reduce(Object) { |mod, part| mod.const_get(part) }.send(:remove_const, name)
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

    expect(File.read(File.join(@root, 'app/graphql/api/queries/feed.rb')).sub("# frozen_string_literal: true\n\n", '')).to match(/\Amodule Api\n  module Queries\n.*    class Feed < GraphQL::Schema::Resolver/m)
    expect(File).to exist(File.join(@root, 'app/graphql/scopes/scoped.rb'))
  end
end
