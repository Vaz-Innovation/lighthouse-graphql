# frozen_string_literal: true

require 'tmpdir'

RSpec.describe Lighthouse::GraphQL::SchemaPrinter do
  let(:schema) do
    build_schema(<<~GRAPHQL)
      type Query {
        widgets(rank: Int @eq, name: String @eq): [Widget!]! @all
        alpha: String
      }

      type Widget { name: String id: ID! }
    GRAPHQL
  end
  let(:dir) { Pathname(Dir.mktmpdir) }

  after { FileUtils.remove_entry(dir) }

  describe '.print' do
    it 'prints the SDL clients see, with no Lighthouse directive, in alphabetical order as PHP Lighthouse --sort' do
      printed = described_class.print(schema)

      expect(printed).to include("type Query {\n  alpha: String\n  widgets(name: String, rank: Int): [Widget!]!\n}")
      expect(printed).to include("type Widget {\n  id: ID!\n  name: String\n}")
      expect(printed).not_to include('@all', '@eq')
    end

    it "prints the introspection result as JSON, as PHP Lighthouse's --json" do
      json = JSON.parse(described_class.print(schema, format: 'json'))

      expect(json['__schema']['types'].pluck('name')).to include('Widget', 'Query')
      expect(json['__schema']['directives'].pluck('name')).not_to include('all', 'eq')
    end

    it 'refuses an unknown format, and federation for a schema without it' do
      expect { described_class.print(schema, format: 'federation') }.to raise_error(ArgumentError, /needs a federated schema/)
      expect { described_class.print(schema, format: 'xml') }.to raise_error(ArgumentError, /Unknown schema format/)
    end
  end

  describe '.write' do
    it 'writes only when the content changed, and leaves no temporary file' do
      path = dir.join('nested/schema.graphql')

      expect(described_class.write(path, "a\n")).to be(true)
      expect(described_class.write(path, "a\n")).to be(false)
      expect(described_class.write(path, "b\n")).to be(true)
      expect(path.read).to eq("b\n")
      expect(path.dirname.children.map { |child| child.basename.to_s }).to eq(['schema.graphql'])
    end
  end

  describe 'Config.schema_output' do
    before { stub_const('PrinterSpecSchema', schema) }

    it 'takes a path, the format from its extension, or a Hash' do
      Lighthouse::Config.schema_output = dir.join('schema.json').to_s
      expect(described_class.output).to include(path: dir.join('schema.json'), format: 'json')

      Lighthouse::Config.schema_output = { path: dir.join('schema.graphql'), schema: 'PrinterSpecSchema' }
      expect(described_class.output).to include(format: 'sdl', schema: 'PrinterSpecSchema')
    end

    it 'is stale until written, then up to date' do
      Lighthouse::Config.schema_output = { path: dir.join('schema.graphql'), schema: 'PrinterSpecSchema' }
      setting = described_class.output

      expect(described_class.stale?(setting)).to be(true)
      described_class.write(setting[:path], described_class.output_content(setting))
      expect(described_class.stale?(setting)).to be(false)
    end
  end
end
