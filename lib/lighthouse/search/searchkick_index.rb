# frozen_string_literal: true

# What the engine tells of an index that Search::Searchkick needs: the fields
# its mapping holds (@trashed's column) and its index.max_result_window. Each is
# read from the engine once per INDEX_READ_TTL seconds per model class and
# index, since a reindex changes them; a read that fails is kept FAILED_READ_TTL
# seconds, so that however many requests ask, the engine is asked at most once
# in that time. A class code reloading makes is read again.
class Lighthouse::Search::Searchkick::Index
  INDEX_READ_TTL = 60
  FAILED_READ_TTL = 5

  # `clock`: seconds, monotonic.
  def initialize(clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
    @clock = clock
    @reads = {}
  end

  # The fields the index `name` holds, or nil when its mapping cannot be read (no
  # index yet). A field every document leaves null has no mapping yet.
  def fields(model, name)
    read(:mapping, model, name) do
      ::Searchkick.client.indices.get_mapping(index: name).to_h.values.flat_map { |mapping| mapping.dig('mappings', 'properties')&.keys || [] }
    end
  end

  # The index's max_result_window: the smallest of an alias's indices, the engines'
  # default (Search::Result::MAX_WINDOW) for one that sets none; nil when its
  # settings cannot be read.
  def result_window(model, name)
    read(:window, model, name) do
      windows = ::Searchkick.client.indices.get_settings(index: name).to_h.values.map do |index|
        index.dig('settings', 'index', 'max_result_window')
      end
      windows.map { |window| window ? Integer(window) : Lighthouse::Search::Result::MAX_WINDOW }.min
    end
  end

  private

  # What the block reads, kept; nil when it raises or reads nothing.
  def read(kind, model, name)
    key = [kind, model.name, name]
    model_class, value, expires = @reads[key]
    return value if model_class.equal?(model) && @clock.call < expires

    value = begin
      yield
    rescue StandardError
      nil
    end
    @reads[key] = [model, value, @clock.call + (value.nil? ? FAILED_READ_TTL : INDEX_READ_TTL)]
    value
  end
end
