# frozen_string_literal: true

require 'rails/railtie'
require 'lighthouse/railtie'

RSpec.describe Lighthouse::Railtie do
  let(:config) { Struct.new(:watchable_dirs).new({}) }

  before { Lighthouse.configure { |c| c.schema_path = '/app/graphql/schema.graphql' } }

  it 'watches nothing by default' do
    expect(described_class.watch_sdl(config)).to be(false)
    expect(config.watchable_dirs).to be_empty
  end

  it "adds the schema's folder to the watched dirs with watch_sdl" do
    Lighthouse.configure { |c| c.watch_sdl = true }

    expect(described_class.watch_sdl(config)).to be(true)
    expect(config.watchable_dirs).to eq('/app/graphql' => %w[graphql graphqls])
  end

  it 'runs after the app initializers and before Rails builds its file watcher' do
    initializer = described_class.initializers.find { |i| i.name == 'lighthouse.watch_sdl' }

    expect(initializer.after).to eq(:load_config_initializers)
    expect(initializer.before).to eq(:set_clear_dependencies_hook)
  end

  it 'refreshes the IDE helper files, and reports the schema, whenever the app is prepared' do
    expect(described_class.initializers.map(&:name)).to include('lighthouse.ide_helper', 'lighthouse.schema_report')
  end
end
