# frozen_string_literal: true

require 'tmpdir'

RSpec.describe Lighthouse::GraphQL::SchemaCache do
  let(:sdl) do
    <<~GRAPHQL
      type Query {
        widgets(email: String @eq): [Widget!]! @paginate(model: "Widget")
      }

      type Widget {
        id: ID!
        email: String
      }
    GRAPHQL
  end

  around do |example|
    Dir.mktmpdir do |dir|
      @dir = dir
      Lighthouse.configure { |c| c.schema_cache_path = dir }
      example.run
    end
  end

  def cache_files
    Dir[File.join(@dir, 'schema-*.bin')]
  end

  def enable!
    Lighthouse.configure { |c| c.schema_cache = true }
  end

  it 'is off by default' do
    build_schema(sdl)

    expect(described_class).not_to be_enabled
    expect(cache_files).to be_empty
  end

  it 'writes the manipulated document on the first build' do
    enable!
    build_schema(sdl)

    expect(cache_files.size).to eq(1)
  end

  it 'skips parsing and manipulation on a cache hit' do
    enable!
    build_schema(sdl)
    allow(Lighthouse::GraphQL::SchemaGenerator).to receive(:manipulate).and_call_original

    build_schema(sdl)

    expect(Lighthouse::GraphQL::SchemaGenerator).not_to have_received(:manipulate)
  end

  it 'builds a schema from the cache that behaves like a fresh one' do
    enable!
    build_schema(sdl)
    Widget.create!(email: 'a@x.y')
    Widget.create!(email: 'b@x.y')

    cached = build_schema(sdl)
    result = cached.execute('{ widgets(first: 10, email: "b@x.y") { paginatorInfo { total } data { email } } }').to_h

    expect(result).to eq('data' => { 'widgets' => { 'paginatorInfo' => { 'total' => 1 }, 'data' => [{ 'email' => 'b@x.y' }] } })
  end

  describe 'its key' do
    let!(:original) { described_class.key(sdl) }

    it 'changes with the SDL' do
      expect(described_class.key("#{sdl}\nscalar Extra")).not_to eq(original)
    end

    it 'changes when a directive is registered' do
      registry = Lighthouse::DirectiveRegistry.default
      registry.register_definition('cacheSpecProbe', 'directive @cacheSpecProbe on FIELD_DEFINITION')

      expect(described_class.key(sdl)).not_to eq(original)
    ensure
      registry.instance_variable_get(:@definitions).delete('cacheSpecProbe')
    end

    it 'changes with the configuration the manipulators read' do
      Lighthouse.configure { |c| c.pagination_default_count = 25 }

      expect(described_class.key(sdl)).not_to eq(original)
    end

    it "changes when a manipulator's source changes" do
      manipulator = Class.new { def self.manipulate(sdl) = sdl }
      allow(described_class).to receive(:source_digest).and_call_original
      allow(described_class).to receive(:source_digest).with(manipulator).and_return('v1', 'v2')
      registry = Lighthouse::DirectiveRegistry.default
      registry.register_manipulator(manipulator)

      expect(described_class.key(sdl)).not_to eq(described_class.key(sdl))
    ensure
      registry.sdl_manipulators.delete(manipulator)
    end
  end

  it 'rebuilds over a corrupt cache file' do
    enable!
    build_schema(sdl)
    File.binwrite(cache_files.first, 'not a marshalled document')

    expect { build_schema(sdl) }.not_to raise_error
    expect(described_class.read(cache_files.first)).to be_a(GraphQL::Language::Nodes::Document)
  end

  it "keeps only the current schema's entry" do
    enable!
    build_schema(sdl)
    build_schema("#{sdl}\nscalar Extra")

    expect(cache_files.size).to eq(1)
    expect(File.basename(cache_files.first)).to eq("schema-#{described_class.key("#{sdl}\nscalar Extra")}.bin")
  end

  it 'warms and clears the cache' do
    path = described_class.warm!(sdl)

    expect(File).to exist(path)
    expect(described_class).not_to be_enabled
    described_class.clear!
    expect(cache_files).to be_empty
  end
end
