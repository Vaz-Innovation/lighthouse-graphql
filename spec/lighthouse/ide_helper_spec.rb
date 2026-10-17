# frozen_string_literal: true

require 'rake'
require 'tmpdir'

RSpec.describe Lighthouse::IdeHelper do
  let(:sdl) do
    <<~GRAPHQL
      directive @field(resolver: String!) on FIELD_DEFINITION

      type Query {
        widgets(where: _ @whereConditions(columns: ["name"])): [Widget!]! @paginate
        widget(id: ID! @eq): Widget @find
      }

      type Widget {
        id: ID!
        name: String
        label: String @field(resolver: "Labels")
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
      expect(output).to include('type WidgetPaginator', 'type PaginatorInfo', 'enum SQLOperator',
                                'input QueryWidgetsWhereWhereConditions')
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
    it 'writes both files from the SDL folder into the output directory' do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, 'schema.graphql'), sdl)
        paths = described_class.write(output_dir: File.join(dir, 'ide'), sdl_folder: dir)

        expect(paths.map { |p| File.basename(p) })
          .to eq([described_class::DIRECTIVES_FILE, described_class::PROGRAMMATIC_TYPES_FILE])
        expect(File.read(paths.last)).to include('type WidgetPaginator')
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

    it 'writes the files to OUTPUT using the configured sdl_folder' do
      File.write(File.join(sdl_dir, 'schema.graphql'), sdl)
      allow(Lighthouse::Config).to receive(:sdl_folder).and_return(sdl_dir)
      stub_const('ENV', ENV.to_h.merge('OUTPUT' => File.join(sdl_dir, 'out')))

      expect { Rake::Task['lighthouse:ide_helper'].invoke }.to output(/Wrote .*schema-directives\.graphql/).to_stdout
      expect(File).to exist(File.join(sdl_dir, 'out', described_class::PROGRAMMATIC_TYPES_FILE))
    end
  end
end
