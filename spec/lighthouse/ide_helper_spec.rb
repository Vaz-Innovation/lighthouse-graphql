# frozen_string_literal: true

require 'rake'
require 'tmpdir'

RSpec.describe Lighthouse::IdeHelper do
  let(:sdl) do
    <<~GRAPHQL
      directive @field(resolver: String!) on FIELD_DEFINITION

      type Query {
        widgets(where: _ @whereConditions(columns: ["name"]), orderBy: _ @orderBy(columns: ["name"])): [Widget!]! @paginate
        widget(id: ID! @eq): Widget @find @canFind(ability: "view", find: "id") @cacheControl(maxAge: 1)
      }

      type Widget @node {
        id: ID!
        name: String
        label: String @field(resolver: "Labels")
        tags(where: _ @whereConditions, kind: String @eq): [String!]! @builder(method: "Tags@call")
      }
    GRAPHQL
  end

  describe '.directives_sdl' do
    subject(:output) { described_class.directives_sdl(sdl) }

    it 'defines every built-in directive the SDL does not declare' do
      %w[all find paginate hasMany belongsTo eq orderBy builder whereConditions guard can].each do |name|
        expect(output).to include("directive @#{name}")
      end
    end

    it 'leaves out directives the SDL declares itself' do
      expect(output).not_to include('directive @field')
    end

    it 'is valid SDL' do
      expect { GraphQL::Language::Parser.parse(output) }.not_to raise_error
    end
  end

  describe '.programmatic_types_sdl' do
    subject(:output) { described_class.programmatic_types_sdl(sdl) }

    it 'contains the types the manipulation phase generates' do
      expect(output).to include('type WidgetPaginator', 'type PaginatorInfo', 'enum SQLOperator', 'enum SortOrder',
                                'input QueryWidgetsWhereWhereConditions', 'input QueryWidgetsOrderByOrderByClause',
                                'enum QueryWidgetsOrderByColumn')
    end

    # graphql-js, which the VS Code and JetBrains plugins build the schema with,
    # rejects a type defined twice; graphql-ruby keeps the last one.
    it 'defines no type the SDL or schema-directives.graphql defines' do
      documents = [sdl, described_class.directives_sdl(sdl), output].map { |text| GraphQL::Language::Parser.parse(text) }
      names = documents.flat_map do |document|
        document.definitions.filter_map do |d|
          d.name unless d.is_a?(GraphQL::Language::Nodes::DirectiveDefinition) || !d.respond_to?(:name)
        end
      end

      expect(names.tally.select { |_, count| count > 1 }.keys).to eq([])
    end

    it 'declares the `_` placeholder the SDL references' do
      expect(output).to include('scalar _')
    end

    it 'leaves out the types the SDL defines itself' do
      expect(output).not_to include('type Widget {', 'type Query')
    end

    it 'together with the SDL and the directives, forms a schema that builds' do
      combined = [sdl, described_class.directives_sdl(sdl), output].join("\n")
      expect { GraphQL::Schema.from_definition(combined) }.not_to raise_error
    end
  end

  describe '.write' do
    it 'writes both files from the schema and its imports into the output directory' do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, 'schema.graphql'), "#import widgets.graphql\n")
        File.write(File.join(dir, 'widgets.graphql'), sdl)
        paths = described_class.write(output_dir: File.join(dir, 'ide'), schema_path: File.join(dir, 'schema.graphql'))

        expect(paths.map { |p| File.basename(p) })
          .to eq([described_class::DIRECTIVES_FILE, described_class::PROGRAMMATIC_TYPES_FILE])
        expect(File.read(paths.last)).to include('type WidgetPaginator')
      end
    end

    it 'keeps the programmatic types of a schema that stops building, and declares `_` when there are none' do
      Dir.mktmpdir do |dir|
        schema = File.join(dir, 'schema.graphql')
        File.write(schema, sdl)
        path = described_class.write(output_dir: dir, schema_path: schema).last
        File.write(schema, "#{sdl}\ntype Widget { id: ID }\n")

        expect { described_class.write(output_dir: dir, schema_path: schema) }.to output(/kept as it was.*Duplicate definition Widget/).to_stderr
        expect(File.read(path)).to include('type WidgetPaginator')

        File.delete(path)
        expect { described_class.write(output_dir: dir, schema_path: schema) }.to output(/kept as it was/).to_stderr
        expect(File.read(path)).to include('scalar _')
        expect(File.read(path)).not_to include('WidgetPaginator')
      end
    end

    it 'reads every .graphql file of the folder when an import is missing, as the IDE does' do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, 'schema.graphql'), "#import missing.graphql\n")
        File.write(File.join(dir, 'widgets.graphql'), sdl)
        paths = described_class.write(output_dir: dir, schema_path: File.join(dir, 'schema.graphql'))

        expect(File.read(paths.first)).to include('directive @paginate')
      end
    end

    it 'leaves a file whose content has not changed alone' do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, 'schema.graphql'), sdl)
        path = described_class.write(output_dir: dir, schema_path: File.join(dir, 'schema.graphql')).last
        File.utime(Time.at(0).utc, Time.at(0).utc, path)
        described_class.write(output_dir: dir, schema_path: File.join(dir, 'schema.graphql'))

        expect(File.mtime(path)).to eq(Time.at(0).utc)
      end
    end
  end

  describe '.refresh' do
    it 'writes nothing unless Config.ide_helper is on' do
      Lighthouse.configure { |c| c.ide_helper = false }

      expect(described_class.refresh(output_dir: '/nonexistent')).to eq([])
    end

    it 'only warns when the schema does not load' do
      Lighthouse.configure do |c|
        c.ide_helper = true
        c.schema_path = '/nonexistent/schema.graphql'
      end

      Dir.mktmpdir do |dir|
        allow(described_class).to receive(:write).and_raise(Lighthouse::DefinitionError, 'broken')
        expect { described_class.refresh(output_dir: dir) }.to output(/not refreshed: broken/).to_stderr
      end
    end
  end

  describe 'the lighthouse:ide_helper rake task' do
    around do |example|
      Rake.application = Rake::Application.new
      Rake::Task.define_task(:environment)
      load File.expand_path('../../lib/lighthouse/tasks/lighthouse.rake', __dir__)
      example.run
    ensure
      Rake.application = Rake::Application.new
    end

    let(:sdl_dir) { Dir.mktmpdir }

    after { FileUtils.remove_entry(sdl_dir) }

    it 'writes the files to OUTPUT using the configured schema_path' do
      File.write(File.join(sdl_dir, 'schema.graphql'), sdl)
      allow(Lighthouse::Config).to receive(:schema_path).and_return(File.join(sdl_dir, 'schema.graphql'))
      stub_const('ENV', ENV.to_h.merge('OUTPUT' => File.join(sdl_dir, 'out')))

      expect { Rake::Task['lighthouse:ide_helper'].invoke }.to output(/Wrote .*schema-directives\.graphql/).to_stdout
      expect(File).to exist(File.join(sdl_dir, 'out', described_class::PROGRAMMATIC_TYPES_FILE))
    end
  end
end
