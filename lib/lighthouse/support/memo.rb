# frozen_string_literal: true

# What a block works out for a key, kept: the one cache of what Lighthouse
# reads of a model or an index (Search::Searchkick, Search::Searchkick::Index).
#
# - A value belongs to the class it was worked out for (`owner`): a class code
#   reloading makes, under the same name, is worked out again.
# - With `ttl:`, a value is worked out again once it is that many seconds old;
#   without, it is kept.
# - With `failed_ttl:`, a block that raises is kept as a failure that long
#   (`get` answers nil, `failure` the error), and `on_failure` hears of it
#   once; without, the error is raised.
# - One block at a time works out a key: other threads asking for it meanwhile
#   wait and take its value, so the source is asked once however many ask.
class Lighthouse::Support::Memo
  Entry = Struct.new(:owner, :value, :error, :expires)

  # What the block works out for `object` (a field's definition), kept on it as
  # `name`: worked out once, the first time it is asked (when the schema is
  # built), and gone with the object, as a schema built again on reload is.
  def self.on(object, name)
    ivar = :"@lighthouse_#{name}"
    return object.instance_variable_get(ivar) if object.instance_variable_defined?(ivar)

    object.instance_variable_set(ivar, yield)
  end

  # `clock`: seconds, monotonic.
  def initialize(ttl: nil, failed_ttl: nil, on_failure: nil, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
    @ttl = ttl
    @failed_ttl = failed_ttl
    @on_failure = on_failure
    @clock = clock
    @entries = {}
    @locks = {}
    @lock = Mutex.new
  end

  # The value for `key` and `owner`, worked out by the block when none is kept.
  def get(key, owner = nil, &block)
    entry = kept(key, owner)
    return entry.value if entry

    lock_for(key).synchronize do
      entry = kept(key, owner) || (@entries[key] = work_out(owner, &block))
      entry.value
    end
  end

  # The error the last block for `key` raised, while its failure is kept; else nil.
  def failure(key, owner = nil) = kept(key, owner)&.error

  private

  def kept(key, owner)
    entry = @entries[key]
    return nil unless entry && entry.owner.equal?(owner)

    entry if entry.expires.nil? || @clock.call < entry.expires
  end

  def work_out(owner)
    Entry.new(owner, yield, nil, @ttl && (@clock.call + @ttl))
  rescue StandardError => e
    raise unless @failed_ttl

    @on_failure&.call(e)
    Entry.new(owner, nil, e, @clock.call + @failed_ttl)
  end

  def lock_for(key) = @lock.synchronize { @locks[key] ||= Mutex.new }
end
