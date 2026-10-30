# frozen_string_literal: true

require 'json'

# Config.persisted_queries_manifest's operations by hash: from a JSON file
# (reloaded when it changes), a Hash, or a callable answering either. Each id
# is checked to be the SHA-256 of its body, once per file version or content.
module Lighthouse::GraphQL::PersistedQueries::Manifest
  module_function

  def operations
    source = Lighthouse::Config.persisted_queries_manifest
    source = source.call if source.respond_to?(:call)
    return {} unless source
    return cached(source) { load(source, 'persisted_queries_manifest') } if source.is_a?(Hash)

    path = source.to_s
    cached([path, File.mtime(path)]) { load(JSON.parse(File.read(path)), path) }
  end

  # The block's operations, checked once per `key`: a file's path and mtime, or a Hash's content.
  def cached(key)
    return @operations if @key == key

    @operations = yield
    @key = key.dup
    @operations
  end

  def load(data, origin)
    data = data.deep_stringify_keys
    operations = data['operations'].is_a?(Array) ? data['operations'].to_h { |op| [op['id'], op['body']] } : data
    operations.each do |hash, body|
      next if Lighthouse::GraphQL::PersistedQueries.digest(body.to_s) == hash

      raise Lighthouse::DefinitionError, "#{origin}: operation #{hash} is not the SHA-256 of its body."
    end
    operations
  end
end
