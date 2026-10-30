# frozen_string_literal: true

require 'digest'
require 'json'

# Automatic Persisted Queries, compatible with Apollo's protocol (as PHP
# Lighthouse supports them), plus a manifest of trusted operations.
#
# APQ: a client sends `extensions: { persistedQuery: { version: 1,
# sha256Hash } }` without the query. A known hash is served from
# Config.persisted_queries_store; an unknown one answers
# PersistedQueryNotFound, and the client retries with the query and the
# hash, which registers it. Requests shrink to a hash, and fit in a GET —
# which CDNs can cache (see @cacheControl).
#
# Manifest: `Config.persisted_queries_manifest` names the operations your
# client build generated — Apollo's persisted query manifest
# (`{ "operations": [{ "id": sha256, "body": query }] }`) or a plain
# `{ sha256 => query }` object (graphql-codegen's persisted documents): a
# JSON file, reloaded when it changes; a Hash of them; or a callable
# answering either, called for every persisted query (a Hash it answers
# again is not checked again). Its operations are served from memory, never
# evicted. With
# `persisted_queries_only`, nothing else runs: an allowlist ("trusted
# documents"), so arbitrary queries cannot reach the API.
#
# Off by default. Run operations through `PersistedQueries.execute` (the
# generated controller does).
module Lighthouse::GraphQL::PersistedQueries
  HASH = /\A\h{64}\z/

  # A request the persisted-query protocol rejects, rendered as a GraphQL
  # response with Apollo's error codes.
  class Error < StandardError
    attr_reader :code

    def initialize(message, code)
      super(message)
      @code = code
    end

    def to_h
      { 'errors' => [{ 'message' => message, 'extensions' => { 'code' => code } }] }
    end
  end

  NOT_FOUND = %w[PersistedQueryNotFound PERSISTED_QUERY_NOT_FOUND].freeze
  NOT_SUPPORTED = %w[PersistedQueryNotSupported PERSISTED_QUERY_NOT_SUPPORTED].freeze
  HASH_MISMATCH = ['provided sha does not match query', 'INTERNAL_SERVER_ERROR'].freeze
  NOT_IN_LIST = ['Only persisted queries are allowed.', 'PERSISTED_QUERY_NOT_IN_LIST'].freeze

  module_function

  # `schema.execute` with the query the request names; a protocol error
  # comes back as a ready-to-render { "errors" => [...] } Hash. Dispatches
  # StartOperationOrOperations before and EndOperationOrOperations after.
  def execute(schema, query:, extensions: nil, **options)
    operation(query, extensions, options) { |text| schema.execute(text, **options) }
  end

  # `execute` for a response that may be streamed (Defer): the Incremental::Run
  # of the query, started (its first pass has run), or the ready-to-render Hash
  # of a protocol error. Dispatches the same events as `execute`, the end one
  # with the first pass's result.
  def incremental(schema, query:, extensions: nil, **options)
    operation(query, extensions, options) { |text| Lighthouse::GraphQL::Incremental::Run.new(schema, text, **options).start }
  end

  # What `execute` and `incremental` share: the block runs the query the request names
  # (`text`), between StartOperationOrOperations and EndOperationOrOperations; a protocol
  # error comes back as its Hash.
  def operation(query, extensions, options)
    operation = { query: query, variables: options[:variables], operation_name: options[:operation_name], extensions: extensions }
    Lighthouse::Events.dispatch(Lighthouse::Events::StartOperationOrOperations.new(operation))
    result =
      begin
        yield resolve(query, extensions)
      rescue Error => e
        e.to_h
      end
    ended = result.is_a?(Lighthouse::GraphQL::Incremental::Run) ? result.result : result
    Lighthouse::Events.dispatch(Lighthouse::Events::EndOperationOrOperations.new(ended))
    result
  end

  # A batch (a JSON array in the request) through `schema.multiplex`; see Batch.
  def multiplex(schema, operations, **options)
    Lighthouse::GraphQL::PersistedQueries::Batch.run(schema, operations, **options)
  end

  # The query text to run for a request's `query` and `extensions`.
  def resolve(query, extensions)
    persisted = persisted_query(extensions)
    query = nil if query.respond_to?(:empty?) && query.empty?
    return unpersisted(query) unless persisted

    hash = supported_hash(persisted)
    query ? register_from_request(query, hash) : lookup(hash)
  end

  # The hash a `persistedQuery` extension names, provided persisted queries
  # are on and it speaks the one protocol version there is.
  def supported_hash(persisted)
    raise Error.new(*NOT_SUPPORTED) unless enabled?

    hash = persisted['sha256Hash'].to_s
    raise Error.new(*NOT_SUPPORTED) unless persisted['version'].to_i == 1 && hash.match?(HASH)

    hash
  end

  def enabled?
    Lighthouse::Config.persisted_queries
  end

  def digest(query)
    Digest::SHA256.hexdigest(query)
  end

  # Store a query ahead of time (e.g. from a deploy task). Returns its hash.
  def register(query)
    digest(query).tap { |hash| store.write(key(hash), query, expires_in: Lighthouse::Config.persisted_queries_ttl) }
  end

  def lookup(hash)
    manifest[hash] || (!only? && store.read(key(hash))) || raise(Error.new(*NOT_FOUND))
  end

  # The manifest's operations by hash (Manifest).
  def manifest = Lighthouse::GraphQL::PersistedQueries::Manifest.operations

  def store
    Lighthouse::Config.persisted_queries_store
  end

  def key(hash)
    "lighthouse:apq:#{hash}"
  end

  def only?
    Lighthouse::Config.persisted_queries_only
  end

  def persisted_query(extensions)
    extensions = extensions_hash(extensions)
    return nil unless extensions.respond_to?(:to_h)

    persisted = extensions.to_h.transform_keys(&:to_s)['persistedQuery']
    persisted&.to_h&.transform_keys(&:to_s)
  rescue JSON::ParserError
    nil
  end

  # `extensions` as the request carries it — a JSON string (GET) or
  # ActionController::Parameters — made a plain Hash where possible. Malformed
  # JSON raises JSON::ParserError, which persisted_query treats as "none".
  def extensions_hash(extensions)
    extensions = JSON.parse(extensions) if extensions.is_a?(String) && !extensions.empty?
    extensions.respond_to?(:to_unsafe_h) ? extensions.to_unsafe_h : extensions
  end

  # A plain query: allowed, unless only the manifest's operations may run.
  def unpersisted(query)
    return query unless only?
    raise Error.new(*NOT_IN_LIST) unless query && manifest.key?(digest(query))

    query
  end

  def register_from_request(query, hash)
    raise Error.new(*HASH_MISMATCH) unless digest(query) == hash
    return query if manifest.key?(hash)
    raise Error.new(*NOT_IN_LIST) if only?

    store.write(key(hash), query, expires_in: Lighthouse::Config.persisted_queries_ttl)
    query
  end
end
