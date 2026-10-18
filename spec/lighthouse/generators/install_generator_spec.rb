# frozen_string_literal: true

require 'tmpdir'
require 'rails/version'
require 'generators/lighthouse/install/install_generator'
require 'generators/graphql/install/mutation_root_generator'

RSpec::Matchers.define_negated_matcher :exclude, :include

# lighthouse:install on top of graphql-ruby's own `graphql:install`, run here for
# real, with its options, in an empty app.
RSpec.describe Lighthouse::Generators::InstallGenerator do
  let(:root) { Dir.mktmpdir }

  before do
    FileUtils.mkdir_p(File.join(root, 'config'))
    File.write(File.join(root, 'config/routes.rb'), "Rails.application.routes.draw do\nend\n")
    File.write(File.join(root, 'config/application.rb'), "module Demo\n  class Application < Rails::Application\n  end\nend\n")
    File.write(File.join(root, 'Gemfile'), "source 'https://rubygems.org'\n")
    File.write(File.join(root, '.gitignore'), "/log/*\n")
    # graphql-ruby's install reads the Gemfile and config/application.rb through Rails.root.
    allow(Rails).to receive(:root).and_return(Pathname.new(root))
  end

  after { FileUtils.remove_entry(root) }

  def quietly
    original = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = original
  end

  # `rails g graphql:install`, with graphql-ruby's options.
  def graphql_install(*args)
    quietly { Graphql::Generators::InstallGenerator.start(['--schema=DemoSchema', *args], destination_root: root) }
  end

  def run_generator(*args)
    quietly { described_class.start(args, destination_root: root) }
  end

  def read(path) = File.read(File.join(root, path))

  def exist?(path) = File.exist?(File.join(root, path))

  describe "on graphql-ruby's install, with its defaults" do
    before do
      graphql_install
      run_generator
    end

    it "makes graphql-ruby's schema class Lighthouse's, built on every class its install wrote" do
      schema = read('app/graphql/demo_schema.rb')

      expect(schema).to include('class DemoSchema < Lighthouse::GraphQL::RbLightHouse.get_schema(')
      expect(schema.squeeze(' ')).to include(
        'query_type: Types::QueryType', 'mutation_type: Types::MutationType', 'node: Types::NodeType',
        'resolver: Resolvers::BaseResolver', 'mutation: Mutations::BaseMutation', 'object: Types::BaseObject',
        'interface: Types::BaseInterface', 'union: Types::BaseUnion', 'scalar: Types::BaseScalar', 'enum: Types::BaseEnum',
        'input_object: Types::BaseInputObject'
      )
      expect(schema).not_to include('subscription:')
    end

    it 'keeps the rest of the class, but the root types it is built on and the resolve_type stub' do
      schema = read('app/graphql/demo_schema.rb')

      expect(schema).to include('use GraphQL::Dataloader', 'def self.type_error', 'max_depth(15)', 'max_query_string_tokens(5000)',
                                'validate_max_errors(100)', 'def self.id_from_object', 'def self.object_from_id')
      expect(schema).not_to include('query(Types::QueryType)', 'mutation(Types::MutationType)', 'def self.resolve_type',
                                    'RequiredImplementationMissingError')
      expect { RubyVM::InstructionSequence.compile(schema) }.not_to raise_error
    end

    it "drops the example field from the root types, keeping Relay's node and nodes" do
      expect(read('app/graphql/types/query_type.rb')).to include('field :node,', 'field :nodes,').and exclude('test_field', 'TODO')
      expect(read('app/graphql/types/mutation_type.rb')).to eq(<<~RUBY)
        # frozen_string_literal: true

        module Types
          class MutationType < Types::BaseObject
          end
        end
      RUBY
    end

    it "makes every type class Lighthouse's through graphql-ruby's bases, and keeps its base mutation" do
      concern = "    # Lighthouse's: the class of the SDL type of its name lends that type its methods.\n    include Lighthouse::GraphQL::Type\n"
      expect(read('app/graphql/types/base_object.rb')).to include("class BaseObject < GraphQL::Schema::Object\n#{concern}")
      expect(read('app/graphql/types/base_union.rb')).to include("class BaseUnion < GraphQL::Schema::Union\n#{concern}")
      expect(read('app/graphql/types/base_scalar.rb')).to include("class BaseScalar < GraphQL::Schema::Scalar\n#{concern}")
      expect(read('app/graphql/types/base_interface.rb')).to include("include GraphQL::Schema::Interface\n#{concern}")
      expect(read('app/graphql/types/node_type.rb')).not_to include('Lighthouse')
      expect(read('app/graphql/mutations/base_mutation.rb')).to include('class BaseMutation < GraphQL::Schema::RelayClassicMutation')
    end

    it "serves the schema with Lighthouse's controller concern, through graphql-ruby's one route" do
      expect(read('app/controllers/graphql_controller.rb')).to include('include Lighthouse::GraphQL::Controller', 'lighthouse_schema DemoSchema')
      expect(read('config/routes.rb').scan('graphql#execute').size).to eq(1)
    end

    it 'adds the initializer, the starter SDL and the IDE config' do
      expect(read('config/initializers/lighthouse.rb')).to include('Lighthouse.configure')
      expect(read('graphql/schema.graphql')).to include('type Query')
      expect(YAML.safe_load(read('graphql.config.yml')))
        .to eq('schema' => ['graphql/**/*.graphql', 'schema-directives.graphql', 'programmatic-types.graphql'])
      expect(exist?('app/graphql/subscriptions/base_subscription.rb')).to be(false)
    end

    it 'changes nothing more when it runs again' do
      before = Dir[File.join(root, '**', '*')].select { |path| File.file?(path) }.index_with { |path| File.read(path) }

      output = run_generator

      after = Dir[File.join(root, '**', '*')].select { |path| File.file?(path) }.index_with { |path| File.read(path) }
      expect(after).to eq(before)
      expect(output).to include("app/graphql/demo_schema.rb is Lighthouse's already")
    end
  end

  it "runs graphql:install first when the app has none, with graphql-ruby's defaults" do
    output = run_generator('--schema=DemoSchema')

    expect(output).to include('graphql:install (no graphql-ruby schema found)')
    expect(read('app/graphql/demo_schema.rb')).to include('class DemoSchema < Lighthouse::GraphQL::RbLightHouse.get_schema(')
    expect(exist?('app/graphql/types/node_type.rb')).to be(true)
  end

  it 'lists only what graphql-ruby wrote: --no-relay, --skip-mutation-root-type' do
    graphql_install('--no-relay', '--skip-mutation-root-type')
    run_generator

    schema = read('app/graphql/demo_schema.rb')
    expect(schema).to include('query_type:').and exclude('mutation_type:', 'node:', 'mutation:')
  end

  it 'uses GraphQL::Dataloader beside --batch, as Lighthouse batches through it' do
    graphql_install('--batch')
    run_generator

    expect(read('app/graphql/demo_schema.rb')).to include("use GraphQL::Batch\n  # Lighthouse's directives batch through GraphQL::Dataloader, " \
                                                          "beside GraphQL::Batch.\n  use GraphQL::Dataloader\n")
  end

  it 'writes the subscription base and lists it with --subscriptions' do
    graphql_install
    run_generator('--subscriptions')

    expect(read('app/graphql/subscriptions/base_subscription.rb'))
      .to include("class BaseSubscription < GraphQL::Schema::Subscription\n    include Lighthouse::GraphQL::Subscription")
    expect(read('app/graphql/demo_schema.rb').squeeze(' ')).to include('subscription: Subscriptions::BaseSubscription')
  end

  it 'keeps a controller the app changed, and says how to serve the schema' do
    graphql_install
    File.write(File.join(root, 'app/controllers/graphql_controller.rb'), "class GraphqlController < ApplicationController\n  # mine\nend\n")

    output = run_generator

    expect(read('app/controllers/graphql_controller.rb')).to include('# mine').and exclude('Lighthouse')
    expect(output).to include('include Lighthouse::GraphQL::Controller in it, or keep calling DemoSchema.execute(...)')
  end

  it 'honours --sdl-folder, --skip-controller and --skip-ide, and keeps an SDL the app has' do
    graphql_install
    FileUtils.mkdir_p(File.join(root, 'app/schema'))
    File.write(File.join(root, 'app/schema/mine.graphql'), "type Query { a: String }\n")

    run_generator('--sdl-folder=app/schema', '--skip-controller', '--skip-ide')

    expect(read('config/initializers/lighthouse.rb')).to include("config.sdl_folder = Rails.root.join('app/schema').to_s")
    expect(exist?('app/schema/schema.graphql')).to be(false)
    expect(read('app/controllers/graphql_controller.rb')).to include('DemoSchema.execute(').and exclude('Lighthouse')
    expect(exist?('graphql.config.yml')).to be(false)
  end

  describe 'the schema both installs wrote' do
    before do
      ActiveRecord::Schema.define do
        create_table :users, force: true do |t|
          t.string :name
          t.string :email
        end
      end
      stub_const('User', Class.new(ApplicationRecord) { self.table_name = 'users' })
      User.create!(name: 'Ada Lovelace', email: 'ada@example.com')
      User.create!(name: 'Alan Turing', email: 'alan@example.com')
      graphql_install
      run_generator
      Lighthouse.configure { |c| c.sdl_folder = File.join(root, 'graphql') }
    end

    after { ActiveRecord::Base.connection.drop_table(:users) }

    # The generated files, evaluated inside an anonymous module so their constants
    # never leak; Types:: loads its files on first reference, as Rails' autoloader
    # does (graphql-ruby's BaseObject and BaseConnection refer to each other).
    let(:schema) do
      sandbox = Module.new
      types = Module.new
      types_dir = File.join(root, 'app/graphql/types')
      types.define_singleton_method(:const_missing) do |name|
        file = File.join(types_dir, "#{name.to_s.underscore}.rb")
        return super(name) unless File.exist?(file)

        sandbox.module_eval(File.read(file), file)
        const_get(name)
      end
      sandbox.const_set(:Types, types)
      %w[resolvers/base_resolver mutations/base_mutation demo_schema].each do |path|
        file = File.join(root, "app/graphql/#{path}.rb")
        sandbox.module_eval(File.read(file), file)
      end
      sandbox.const_get(:DemoSchema)
    end

    it "resolves an SDL Query field with Types::QueryType's method of its name, as graphql-ruby does" do
      File.write(File.join(root, 'graphql/greeting.graphql'), "extend type Query { greeting(name: String!): String! }\n")
      query_type = File.join(root, 'app/graphql/types/query_type.rb')
      File.write(query_type, File.read(query_type).sub(/^  end\nend\n\z/, "\n    def greeting(name:) = \"Hello, \#{name}\"\n  end\nend\n"))

      expect(schema.execute('{ greeting(name: "Ada") }').to_h).to eq('data' => { 'greeting' => 'Hello, Ada' })
      expect(schema.types['Node']).to include(Lighthouse::GraphQL::Type)
    end

    it "answers the starter SDL's queries, beside graphql-ruby's Relay fields" do
      users = schema.execute('{ users { data { name } paginatorInfo { total } } }').to_h
      expect(users).to eq('data' => { 'users' => { 'data' => [{ 'name' => 'Ada Lovelace' }, { 'name' => 'Alan Turing' }],
                                                   'paginatorInfo' => { 'total' => 2 } } })

      id = User.find_by(name: 'Alan Turing').id
      expect(schema.execute("{ user(id: #{id}) { email } }").to_h).to eq('data' => { 'user' => { 'email' => 'alan@example.com' } })
      expect(schema.query.fields.keys).to include('node', 'nodes', 'users', 'user')
      expect(schema.max_depth).to eq(15)
    end
  end
end
