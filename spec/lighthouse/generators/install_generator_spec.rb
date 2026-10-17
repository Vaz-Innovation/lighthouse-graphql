# frozen_string_literal: true

require 'tmpdir'
require 'generators/lighthouse/install/install_generator'

RSpec.describe Lighthouse::Generators::InstallGenerator do
  let(:root) { Dir.mktmpdir }

  before do
    FileUtils.mkdir_p(File.join(root, 'config'))
    File.write(File.join(root, 'config/routes.rb'), "Rails.application.routes.draw do\nend\n")
    File.write(File.join(root, '.gitignore'), "/log/*\n")
  end

  after { FileUtils.remove_entry(root) }

  def run_generator(*args)
    capture = StringIO.new
    original = $stdout
    $stdout = capture
    described_class.start(args, destination_root: root)
    capture.string
  ensure
    $stdout = original
  end

  def read(path)
    File.read(File.join(root, path))
  end

  def exist?(path)
    File.exist?(File.join(root, path))
  end

  it 'creates the initializer, starter schema, schema class, controller and IDE config' do
    run_generator

    %w[
      config/initializers/lighthouse.rb
      graphql/schema.graphql
      app/graphql/app_schema.rb
      app/controllers/graphql_controller.rb
      graphql.config.yml
    ].each { |path| expect(exist?(path)).to be(true), "expected #{path}" }
  end

  it 'generates a controller that includes the concern and names the schema' do
    run_generator('--schema=ApiSchema')

    controller = read('app/controllers/graphql_controller.rb')
    expect(controller).to include('include Lighthouse::GraphQL::Controller', 'lighthouse_schema ApiSchema')
  end

  it 'generates Ruby that parses' do
    run_generator

    %w[config/initializers/lighthouse.rb app/graphql/app_schema.rb app/controllers/graphql_controller.rb].each do |path|
      expect { RubyVM::InstructionSequence.compile(read(path)) }.not_to raise_error
    end
  end

  it 'adds the route once, however many times it runs' do
    2.times { run_generator('--skip') }

    expect(read('config/routes.rb').scan('post "/graphql", to: "graphql#execute"').size).to eq(1)
  end

  it 'ignores the IDE helper output in .gitignore, once' do
    2.times { run_generator('--skip') }

    gitignore = read('.gitignore')
    expect(gitignore.scan('/schema-directives.graphql').size).to eq(1)
    expect(gitignore.scan('/programmatic-types.graphql').size).to eq(1)
    expect(gitignore).to start_with("/log/*\n")
  end

  it 'points graphql-config at the SDL and the IDE helper files' do
    run_generator

    expect(YAML.safe_load(read('graphql.config.yml')))
      .to eq('schema' => ['graphql/**/*.graphql', 'schema-directives.graphql', 'programmatic-types.graphql'])
  end

  it 'keeps an existing schema instead of adding the starter one' do
    FileUtils.mkdir_p(File.join(root, 'graphql'))
    File.write(File.join(root, 'graphql/mine.graphql'), "type Query { a: String }\n")

    run_generator

    expect(exist?('graphql/schema.graphql')).to be(false)
  end

  it 'honours --schema, --sdl-folder, --skip-controller and --skip-ide' do
    run_generator('--schema=ApiSchema', '--sdl-folder=app/schema', '--skip-controller', '--skip-ide')

    expect(read('app/graphql/api_schema.rb')).to include('ApiSchema = Lighthouse::GraphQL::RbLightHouse.get_schema')
    expect(read('config/initializers/lighthouse.rb')).to include("config.sdl_folder = Rails.root.join('app/schema').to_s")
    expect(exist?('app/schema/schema.graphql')).to be(true)
    expect(exist?('app/controllers/graphql_controller.rb')).to be(false)
    expect(read('config/routes.rb')).not_to include('graphql#execute')
    expect(exist?('graphql.config.yml')).to be(false)
  end

  context "when the app was set up by graphql-ruby's graphql:install" do
    let(:graphql_ruby_controller) do
      "class GraphqlController < ApplicationController\n  def execute\n    DemoSchema.execute(params[:query])\n  end\nend\n"
    end

    before do
      FileUtils.mkdir_p(File.join(root, 'app/controllers'))
      File.write(File.join(root, 'app/controllers/graphql_controller.rb'), graphql_ruby_controller)
      File.write(File.join(root, 'config/routes.rb'),
                 "Rails.application.routes.draw do\n  post \"/graphql\", to: \"graphql#execute\"\nend\n")
    end

    it 'keeps its controller and route, and says how to serve the Lighthouse schema' do
      output = run_generator

      expect(read('app/controllers/graphql_controller.rb')).to eq(graphql_ruby_controller)
      expect(read('config/routes.rb').scan('graphql#execute').size).to eq(1)
      expect(output).to include('have it call AppSchema.execute(...)')
    end

    it 'keeps an existing schema class of the same name' do
      FileUtils.mkdir_p(File.join(root, 'app/graphql'))
      File.write(File.join(root, 'app/graphql/app_schema.rb'), "class AppSchema < GraphQL::Schema\nend\n")

      run_generator

      expect(read('app/graphql/app_schema.rb')).to eq("class AppSchema < GraphQL::Schema\nend\n")
    end

    it 'replaces them with --force' do
      run_generator('--force')

      expect(read('app/controllers/graphql_controller.rb')).to include('include Lighthouse::GraphQL::Controller', 'lighthouse_schema AppSchema')
    end
  end

  describe 'the starter schema' do
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
    end

    after { ActiveRecord::Base.connection.drop_table(:users) }

    it 'builds and answers the queries it advertises' do
      run_generator
      schema = Lighthouse::GraphQL::RbLightHouse.get_schema(
        sdl_folder: File.join(root, 'graphql'),
        options: { using: { GraphQL::Dataloader => {} } }
      )

      users = schema.execute('{ users { data { name } paginatorInfo { total } } }').to_h
      expect(users).to eq('data' => { 'users' => { 'data' => [{ 'name' => 'Ada Lovelace' }, { 'name' => 'Alan Turing' }],
                                                   'paginatorInfo' => { 'total' => 2 } } })

      id = User.find_by(name: 'Alan Turing').id
      user = schema.execute("{ user(id: #{id}) { email } }").to_h
      expect(user).to eq('data' => { 'user' => { 'email' => 'alan@example.com' } })
    end
  end
end
