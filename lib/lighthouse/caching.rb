# frozen_string_literal: true

require 'active_support/cache'
require 'digest'
require 'json'
require 'securerandom'

# The app's cache stores, and keys and invalidation for @cache / @clearCache.
#
# Lighthouse keeps no store of its own, as PHP Lighthouse uses Laravel's: @cache,
# @clearCache and APQ use Rails.cache (config.cache_store), and @throttle counts
# where Rails' own `rate_limit` does, in the controller's cache_store.
#
# PHP Lighthouse invalidates with cache tags, which Rails cache stores do not
# have (and `delete_matched` is not universal). Instead every entry key embeds
# four version tokens — the type, the type + parent id, the type + field, and
# the type + parent id + field — and @clearCache replaces the matching token.
# Old entries are never read again and expire on their own. A token that
# was evicted is re-created with a fresh value, so eviction only ever causes
# misses, never stale reads.
module Lighthouse::GraphQL::Caching
  PREFIX = 'lighthouse'

  module_function

  # Rails.cache; outside Rails, one in-memory store for the process.
  def store
    rails_cache = ::Rails.cache if defined?(::Rails) && ::Rails.respond_to?(:cache)
    rails_cache || (@memory_store ||= ActiveSupport::Cache::MemoryStore.new)
  end

  def entry_key(type, id, field, args, user_key)
    tokens = versions(version_keys(type, id, field))
    [PREFIX, type, id, field, digest(args), user_key, *tokens].join(':')
  end

  # @clearCache: invalidate everything cached for `type`, narrowed to one
  # parent `id` and/or one `field` when given.
  def clear(type, id: nil, field: nil)
    key = version_key(type, id, field)
    store.write(key, SecureRandom.hex(8))
  end

  def version_keys(type, id, field)
    [version_key(type, nil, nil), version_key(type, id, nil), version_key(type, nil, field), version_key(type, id, field)]
      .uniq
  end

  def version_key(type, id, field)
    [PREFIX, 'version', type, id, field].join(':')
  end

  def versions(keys)
    found = store.read_multi(*keys)
    keys.map do |key|
      found[key] || begin
        store.write(key, SecureRandom.hex(8), unless_exist: true)
        store.read(key)
      end
    end
  end

  def digest(args)
    Digest::SHA256.hexdigest(JSON.generate(canonical(Lighthouse::Support::Arguments.plain(args))))[0, 32]
  end

  def canonical(value)
    case value
    when Hash then value.map { |k, v| [k.to_s, canonical(v)] }.sort_by(&:first)
    when Array then value.map { |v| canonical(v) }
    else value
    end
  end
end
