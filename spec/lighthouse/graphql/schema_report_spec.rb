# frozen_string_literal: true

require 'logger'
require 'stringio'

RSpec.describe Lighthouse::GraphQL::SchemaReport do
  let(:io) { StringIO.new }
  let(:logger) { Logger.new(io, formatter: ->(severity, _time, _progname, message) { "#{severity} #{message}\n" }) }
  let(:schema) { build_schema('type Query { posts: [Post!]! @all } type Mutation { a: Int } type Post { id: ID! title: String }') }

  before do
    described_class.instance_variable_set(:@fingerprints, {})
    Lighthouse.configure { |config| config.schema_log = true }
    stub_const('AppSchema', schema)
  end

  def log(app_schema = schema)
    stub_const('AppSchema', app_schema)
    io.truncate(0) && io.rewind
    described_class.refresh(logger: logger)
    io.string.gsub(/ \d+ ms/, ' N ms')
  end

  it 'logs that the schema built, in how long, and how big it is' do
    expect(log).to eq("INFO [Lighthouse] ✓ AppSchema built in N ms: 3 types, 1 queries, 1 mutations\n")
  end

  it 'logs what a reload added and removed, or that nothing changed' do
    log
    expect(log).to include("INFO [Lighthouse]   unchanged\n")

    changed = build_schema('type Query { posts: [Post!]! @all comments: [Comment!]! } type Post { id: ID! body: String } type Comment { id: ID! }')
    expect(log(changed)).to include('+ Comment   + Post.body   + Query.comments   − Mutation   − Post.title')
  end

  it 'logs why the schema does not build' do
    allow(Lighthouse::GraphQL::SchemaPrinter).to receive(:app_schema)
      .and_raise(Lighthouse::DefinitionError, 'No directive found for `@can` on Query.a.')

    expect(log).to eq(<<~LOG)
      ERROR [Lighthouse] ✗ The schema does not build: Lighthouse::DefinitionError
      ERROR [Lighthouse]   No directive found for `@can` on Query.a.
      ERROR [Lighthouse]   The next GraphQL request raises it: save a fix to reload.
    LOG
  end

  it 'warns of the persisted operations the schema no longer accepts' do
    gone = '{ comments { id } }'
    Lighthouse.configure { |config| config.persisted_queries_manifest = { Digest::SHA256.hexdigest(gone) => gone } }

    expect(log).to include("WARN [Lighthouse] ! Persisted operations the schema no longer accepts: 1\n",
                           "WARN [Lighthouse]   #{Digest::SHA256.hexdigest(gone)[0, 12]}…: Field 'comments' doesn't exist on type 'Query'")
  end

  it 'does nothing with the log off and no schema_output' do
    Lighthouse.configure { |config| config.schema_log = false }

    expect(described_class.refresh(logger: logger)).to be_nil
    expect(io.string).to be_empty
  end
end
