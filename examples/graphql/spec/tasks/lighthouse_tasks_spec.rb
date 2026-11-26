require 'rails_helper'
require 'rake'

RSpec.describe 'lighthouse rake tasks', type: :task do
  let(:dir) { Dir.mktmpdir }

  before { Rails.application.load_tasks unless Rake::Task.task_defined?('lighthouse:cache') }

  after { FileUtils.remove_entry(dir) }

  def run(task, env = {})
    stub_const('ENV', ENV.to_h.merge(env))
    Rake::Task[task].reenable
    Rake::Task[task].invoke
  end

  it 'lighthouse:cache warms the schema cache, lighthouse:clear_cache removes it' do
    Lighthouse.configure { |config| config.schema_cache_path = dir }

    expect { run('lighthouse:cache') }.to output(/Wrote .*schema-\h{64}\.bin/).to_stdout
    expect(Dir.children(dir)).to contain_exactly(match(/\Aschema-\h{64}\.bin\z/))

    expect { run('lighthouse:clear_cache') }.to output(/Cleared/).to_stdout
    expect(Dir.children(dir)).to be_empty
  ensure
    Lighthouse.configure { |config| config.schema_cache_path = nil }
  end

  it 'lighthouse:ide_helper writes the files graphql.config.yml points IDEs at' do
    expect { run('lighthouse:ide_helper', 'OUTPUT' => dir) }.to output.to_stdout

    expect(Dir.children(dir)).to contain_exactly('schema-directives.graphql', 'programmatic-types.graphql')
    expect(File.read(File.join(dir, 'programmatic-types.graphql'))).to include('type PostPaginator', 'type PostConnection')
  end

  it 'lighthouse:print_schema prints the final schema to stdout, with the types Lighthouse generates and no `_`' do
    expect { run('lighthouse:print_schema', 'SCHEMA' => 'AppSchema') }
      .to output(/type PostPaginator.*type Query/m).to_stdout
    expect { run('lighthouse:print_schema', 'SCHEMA' => 'AppSchema') }.not_to output(/scalar _\b|:\s*_\b/).to_stdout
  end

  it 'lighthouse:print_schema prints what clients see: no Lighthouse directive, introspection JSON with FORMAT=json' do
    applied_or_defined = /^\s+\w+(\(.*\))?: \S+ @\w+|^directive @(all|paginate)/
    expect { run('lighthouse:print_schema', 'SCHEMA' => 'AppSchema') }.not_to output(applied_or_defined).to_stdout
    expect { run('lighthouse:print_schema', 'SCHEMA' => 'AppSchema', 'FORMAT' => 'json') }.to output(/"__schema"/).to_stdout
  end

  it 'lighthouse:print_schema WRITE= writes the file, and schema_output:verify fails until it is up to date' do
    path = File.join(dir, 'schema.graphql')
    Lighthouse::Config.schema_output = { path: path, schema: 'AppSchema' }

    expect { run('lighthouse:schema_output:verify') }.to raise_error(SystemExit).and output(/out of date/).to_stderr
    expect { run('lighthouse:print_schema', 'WRITE' => '1') }.to output(/Wrote #{path}/).to_stdout
    expect(File.read(path)).to include('type PostPaginator')
    expect { run('lighthouse:print_schema', 'WRITE' => '1') }.to output(/is up to date/).to_stdout
    expect { run('lighthouse:schema_output:verify') }.to output(/is up to date/).to_stdout
  ensure
    Lighthouse::Config.schema_output = nil
  end

  it 'lighthouse:validate_schema dispatches ValidateSchema and accepts the example schema' do
    listener = Lighthouse::Events.listen(Lighthouse::Events::ValidateSchema, &:schema)

    expect { run('lighthouse:validate_schema', 'SCHEMA' => 'AppSchema') }.to output(/AppSchema is valid/).to_stdout
  ensure
    Lighthouse::Events.forget(listener)
  end

  it 'lighthouse:validate_schema aborts when a listener finds the schema invalid' do
    listener = Lighthouse::Events.listen(Lighthouse::Events::ValidateSchema) { raise 'no good' }

    expect { run('lighthouse:validate_schema', 'SCHEMA' => 'AppSchema') }
      .to raise_error(SystemExit).and output(/AppSchema is invalid: no good/).to_stderr
  ensure
    Lighthouse::Events.forget(listener)
  end

  it 'lighthouse:persisted_queries:verify accepts every operation in persisted-queries.json' do
    expect { run('lighthouse:persisted_queries:verify', 'SCHEMA' => 'AppSchema') }.to output(/2 persisted operations are valid/).to_stdout
  end
end
