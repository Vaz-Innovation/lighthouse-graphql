# frozen_string_literal: true

# What the engine tells of an index that Search::Searchkick needs: the fields
# its mapping holds (@trashed's column) and its index.max_result_window. Each is
# read from the engine once per INDEX_READ_TTL seconds per model class and
# index, since a reindex changes them, by one thread at a time (Support::Memo):
# however many requests ask, the engine is asked once in that time. A read that
# fails is reported to Config.on_error and kept FAILED_READ_TTL seconds, its
# error at hand (`failure`) for the errors that need it. Reading them needs the
# `view_index_metadata` privilege on the index (`monitor` for OpenSearch's
# settings).
class Lighthouse::Search::Searchkick::Index
  INDEX_READ_TTL = 60
  FAILED_READ_TTL = 5

  # `clock`: seconds, monotonic.
  def initialize(clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
    @reads = Lighthouse::Support::Memo.new(ttl: INDEX_READ_TTL, failed_ttl: FAILED_READ_TTL, clock: clock,
                                           on_failure: ->(error) { Lighthouse::Config.handle_error(error, nil) })
  end

  # The fields the index `name` holds, or nil when its mapping cannot be read (no
  # index yet, no privilege). A field every document leaves null has no mapping yet.
  def fields(model, name)
    @reads.get([:mapping, model.name, name], model) do
      next nil unless client

      client.indices.get_mapping(index: name).to_h.values.flat_map { |mapping| mapping.dig('mappings', 'properties')&.keys || [] }
    end
  end

  # The index's max_result_window: the smallest of an alias's indices, the engines'
  # default (Search::Result::MAX_WINDOW) for one that sets none; nil when its
  # settings cannot be read.
  def result_window(model, name)
    @reads.get([:window, model.name, name], model) do
      next nil unless client

      windows = client.indices.get_settings(index: name).to_h.values.map do |index|
        index.dig('settings', 'index', 'max_result_window')
      end
      windows.map { |window| window ? Integer(window) : Lighthouse::Search::Result::MAX_WINDOW }.min
    end
  end

  # Why the last read of the index's `:mapping` or `:window` failed, while that is
  # kept; nil when it did not.
  def failure(kind, model, name) = @reads.failure([kind, model.name, name], model)

  private

  # Searchkick's client; nil for a Searchkick that has none to ask (the suite's).
  def client = (::Searchkick.client if ::Searchkick.respond_to?(:client))
end
