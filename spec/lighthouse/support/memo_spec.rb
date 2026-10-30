# frozen_string_literal: true

require 'spec_helper'

# The one cache of what Lighthouse reads of a model or an index (Search::Searchkick::Index, Search::Searchkick).
RSpec.describe Lighthouse::Support::Memo do
  let(:now) { [0] }
  let(:failures) { [] }
  let(:memo) { described_class.new(ttl: 60, failed_ttl: 5, on_failure: ->(error) { failures << error.message }, clock: -> { now.first }) }

  it 'asks the source once however many threads ask at once, as a value expires' do
    calls = Queue.new
    reads = Array.new(8) do
      Thread.new do
        memo.get(:mapping) do
          calls << true
          sleep 0.05
          %w[title]
        end
      end
    end

    expect(reads.map(&:value)).to all(eq(%w[title]))
    expect(calls.size).to eq(1)
  end

  it 'works a value out again once it is ttl seconds old, and for a class code reloading makes' do
    reloaded = Class.new
    values = [1, 2, 3].each
    read = lambda do |at, owner = Object|
      now[0] = at
      memo.get(:window, owner) { values.next }
    end

    expect([read.call(0), read.call(59), read.call(60), read.call(61, reloaded)]).to eq([1, 1, 2, 3])
  end

  it 'keeps a failure failed_ttl seconds, answering nil, its error at hand, and reports it once' do
    attempts = 0
    read = lambda do |at|
      now[0] = at
      memo.get(:mapping) { (attempts += 1) && raise('view_index_metadata is required') }
    end

    expect([read.call(0), read.call(4)]).to eq([nil, nil])
    expect(memo.failure(:mapping)&.message).to eq('view_index_metadata is required')
    expect([attempts, failures]).to eq([1, ['view_index_metadata is required']])
    read.call(5)
    expect(attempts).to eq(2)
  end

  it 'raises what the block raises without failed_ttl, keeping nothing' do
    plain = described_class.new

    expect { plain.get(:columns) { raise ArgumentError, 'no record' } }.to raise_error(ArgumentError, 'no record')
    expect(plain.get(:columns) { %w[title] }).to eq(%w[title])
  end
end
