# frozen_string_literal: true

require 'tmpdir'
require 'rake'
require 'active_support/testing/time_helpers'

RSpec.describe Lighthouse::GraphQL::PersistedQueries do
  include ActiveSupport::Testing::TimeHelpers

  let(:schema) do
    build_schema(<<~GRAPHQL)
      type Query {
        widgets: [Widget!]! @all @cacheControl(maxAge: 60)
      }

      type Widget @cacheControl(maxAge: 60) {
        id: ID!
        email: String @cacheControl(maxAge: 60)
      }
    GRAPHQL
  end

  let(:query) { '{ widgets { email } }' }
  let(:sha) { Digest::SHA256.hexdigest(query) }

  def apq(hash = sha)
    { 'persistedQuery' => { 'version' => 1, 'sha256Hash' => hash } }
  end

  def run(query: nil, extensions: nil)
    result = described_class.execute(schema, query: query, extensions: extensions)
    result.is_a?(Hash) ? result : result.to_h
  end

  def error(result)
    result['errors']&.first&.then { |e| [e['message'], e.dig('extensions', 'code')] }
  end

  before { Widget.create!(email: 'a@x.y') }

  describe 'when off (the default)' do
    it 'runs plain queries as before' do
      expect(run(query: query)).to eq('data' => { 'widgets' => [{ 'email' => 'a@x.y' }] })
    end

    it 'answers a hash with PersistedQueryNotSupported, so clients fall back to sending the query' do
      expect(error(run(extensions: apq))).to eq(%w[PersistedQueryNotSupported PERSISTED_QUERY_NOT_SUPPORTED])
    end
  end

  describe 'when on' do
    before { Lighthouse.configure { |c| c.persisted_queries = true } }

    it "follows Apollo's handshake: not found, then register with the query, then run by hash alone" do
      expect(error(run(extensions: apq))).to eq(%w[PersistedQueryNotFound PERSISTED_QUERY_NOT_FOUND])
      expect(run(query: query, extensions: apq)).to eq('data' => { 'widgets' => [{ 'email' => 'a@x.y' }] })
      expect(run(extensions: apq)).to eq('data' => { 'widgets' => [{ 'email' => 'a@x.y' }] })
    end

    it 'refuses a query whose hash does not match' do
      expect(error(run(query: query, extensions: apq('0' * 64)))).to eq(['provided sha does not match query', 'INTERNAL_SERVER_ERROR'])
      expect(error(run(extensions: apq('0' * 64)))).to eq(%w[PersistedQueryNotFound PERSISTED_QUERY_NOT_FOUND])
    end

    it 'refuses malformed hashes and unknown protocol versions' do
      expect(error(run(extensions: apq('lighthouse:apq:../../etc')))).to eq(%w[PersistedQueryNotSupported PERSISTED_QUERY_NOT_SUPPORTED])
      expect(error(run(extensions: { 'persistedQuery' => { 'version' => 2, 'sha256Hash' => sha } }))).to eq(%w[PersistedQueryNotSupported PERSISTED_QUERY_NOT_SUPPORTED])
    end

    it 'reads extensions sent as a JSON string, as in a GET request' do
      run(query: query, extensions: apq)

      expect(run(extensions: JSON.generate(apq))).to eq('data' => { 'widgets' => [{ 'email' => 'a@x.y' }] })
    end

    it 'forgets queries after persisted_queries_ttl' do
      Lighthouse.configure { |c| c.persisted_queries_ttl = 60 }
      run(query: query, extensions: apq)

      travel(61.seconds) { expect(error(run(extensions: apq))).to eq(%w[PersistedQueryNotFound PERSISTED_QUERY_NOT_FOUND]) }
    end

    it 'serves queries registered ahead of time' do
      described_class.register(query)

      expect(run(extensions: apq)).to eq('data' => { 'widgets' => [{ 'email' => 'a@x.y' }] })
    end

    it 'keeps the Cache-Control header working on persisted queries' do
      result = described_class.execute(schema, query: query, extensions: apq)
      response = Struct.new(:headers).new({})
      Lighthouse::GraphQL::CacheControl.apply(response, result)

      expect(response.headers).to eq('Cache-Control' => 'max-age=60, public')
      expect(Lighthouse::GraphQL::CacheControl.apply(response, described_class.execute(schema, query: nil, extensions: apq('1' * 64)))).to be_nil
    end
  end

  describe 'with a manifest of trusted operations' do
    around do |example|
      Dir.mktmpdir do |dir|
        @manifest = File.join(dir, 'persisted-queries.json')
        example.run
      end
    end

    let(:other) { '{ widgets { id } }' }

    def write_manifest(operations)
      File.write(@manifest, JSON.generate(operations))
      FileUtils.touch(@manifest, mtime: Time.now + rand(1..1000)) # a distinct mtime, so it is reloaded
    end

    before do
      write_manifest('format' => 'apollo-persisted-query-manifest', 'version' => 1,
                     'operations' => [{ 'id' => sha, 'name' => 'Widgets', 'type' => 'query', 'body' => query }])
      Lighthouse.configure do |c|
        c.persisted_queries = true
        c.persisted_queries_manifest = @manifest
      end
    end

    it "serves the manifest's operations by hash, without a store" do
      expect(run(extensions: apq)).to eq('data' => { 'widgets' => [{ 'email' => 'a@x.y' }] })
    end

    it 'reads a plain { sha256 => query } manifest, and reloads it when it changes' do
      write_manifest(Digest::SHA256.hexdigest(other) => other)

      expect(run(extensions: apq(Digest::SHA256.hexdigest(other)))).to eq('data' => { 'widgets' => [{ 'id' => Widget.first.id.to_s }] })
    end

    it 'rejects a manifest whose ids are not the hashes of their bodies' do
      write_manifest(sha => other)

      expect { run(extensions: apq) }.to raise_error(Lighthouse::DefinitionError, /is not the SHA-256 of its body/)
    end

    describe 'and persisted_queries_only' do
      before { Lighthouse.configure { |c| c.persisted_queries_only = true } }

      it 'runs only the manifest operations, by hash or by text' do
        expect(run(extensions: apq)).to include('data')
        expect(run(query: query)).to include('data')
      end

      it 'rejects any other operation, and does not register it' do
        other_sha = Digest::SHA256.hexdigest(other)

        expect(error(run(query: other))).to eq(['Only persisted queries are allowed.', 'PERSISTED_QUERY_NOT_IN_LIST'])
        expect(error(run(query: other, extensions: apq(other_sha)))).to eq(['Only persisted queries are allowed.', 'PERSISTED_QUERY_NOT_IN_LIST'])
        expect(error(run(extensions: apq(other_sha)))).to eq(%w[PersistedQueryNotFound PERSISTED_QUERY_NOT_FOUND])
      end
    end

    describe 'the lighthouse:persisted_queries:verify task' do
      around do |example|
        Rake.application = Rake::Application.new
        Rake::Task.define_task(:environment)
        load File.expand_path('../../lib/lighthouse/tasks/lighthouse.rake', __dir__)
        example.run
      ensure
        Rake.application = Rake::Application.new
      end

      before { stub_const('PersistedSpecSchema', schema) }

      def verify
        stub_const('ENV', ENV.to_h.merge('SCHEMA' => 'PersistedSpecSchema'))
        Rake::Task['lighthouse:persisted_queries:verify'].invoke
      end

      it 'passes when the schema accepts every operation' do
        expect { verify }.to output(/1 persisted operations are valid/).to_stdout
      end

      it 'fails when a schema change breaks a published operation' do
        broken = '{ widgets { removedField } }'
        write_manifest(Digest::SHA256.hexdigest(broken) => broken)

        expect { verify }.to raise_error(SystemExit).and output(/removedField/).to_stderr
      end
    end
  end
end
