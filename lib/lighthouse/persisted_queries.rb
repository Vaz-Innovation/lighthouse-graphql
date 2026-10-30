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
  # A protocol error raised as the query runs (a resolver asking `resolve`, say) is answered so too.
  def execute(schema, query:, extensions: nil, **options)
    operation(query, extensions, options) do |text, ended|
      protocol { schema.execute(text, **options) }.tap { |result| ended.call(result) }
    end
  end

  # `execute` for a response that may be streamed (Defer): yields the
  # Incremental::Run of the query, started (its first pass has run), and answers
  # what the block answers; or answers the ready-to-render Hash of a protocol
  # error, without yielding. Dispatches the same events as `execute`: for a run
  # that defers nothing, EndOperationOrOperations with its result at once; for one
  # that defers, with the whole response (Incremental::Run#response, the data and
  # errors of every round) once its last round has run, or, if the block streams
  # none, once the block is done.
  #
  # A protocol error raised as the first pass runs is answered as on the JSON path, nothing being
  # sent yet; one raised in a later round fails the stream, as any error of a round does.
  def incremental(schema, query:, extensions: nil, **options)
    operation(query, extensions, options) do |text, ended|
      run = protocol { Lighthouse::GraphQL::Incremental::Run.new(schema, text, **options).start(&ended) }
      next run.tap { |error| ended.call(error) } if run.is_a?(Hash)

      begin
        yield run
      ensure
        run.finish
      end
    end
  end

  # What the block answers, or the Hash of the protocol Error it raises.
  def protocol
    yield
  rescue Error => e
    e.to_h
  end

  # What `execute` and `incremental` share: the block runs the query the request names
  # (`text`) after StartOperationOrOperations, and calls `ended`, once, with what
  # EndOperationOrOperations carries, once it is done. A protocol error (the request's query
  # does not resolve) comes back as its Hash, and ends the operation, the block not run. An
  # error raised elsewhere (a listener, the block) goes through as it is.
  def operation(query, extensions, options)
    operation = { query: query, variables: options[:variables], operation_name: options[:operation_name], extensions: extensions }
    Lighthouse::Events.dispatch(Lighthouse::Events::StartOperationOrOperations.new(operation))
    ended = ->(result) { Lighthouse::Events.dispatch(Lighthouse::Events::EndOperationOrOperations.new(result)) }
    text = protocol { resolve(query, extensions) }
    return text.tap { |error| ended.call(error) } if text.is_a?(Hash)

    yield text, ended
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
