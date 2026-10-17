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

  it 'lighthouse:persisted_queries:verify accepts every operation in persisted-queries.json' do
    expect { run('lighthouse:persisted_queries:verify', 'SCHEMA' => 'AppSchema') }.to output(/2 persisted operations are valid/).to_stdout
  end
end
