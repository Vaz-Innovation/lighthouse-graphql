# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'tmpdir'

# Opt-in cache of the schema document Lighthouse builds from your SDL —
# PHP Lighthouse's schema cache, done the Bootsnap way: a content-addressed
# file in tmp/cache, no deploy step to remember and nothing to clear by hand.
#
# Building a schema parses the SDL, injects directive definitions and runs
# the manipulators (pagination types, whereConditions inputs, ...), parses
# the result and builds the executable schema. The cache stores the parsed,
# manipulated document, so a boot skips everything up to that last step —
# roughly 60% of the build time.
#
# The key covers everything that shapes that document: the SDL, the
# Lighthouse / graphql-ruby / Ruby versions, the registered directive and
# type definitions, the source of the manipulators, and the configuration
# they read. Change any of them and the next boot rebuilds — a stale schema
# cannot be served. Enable with `Lighthouse.configure { |c| c.schema_cache = true }`;
# `bin/rails lighthouse:cache` warms it at deploy (e.g. in a Docker build).
module Lighthouse::GraphQL::SchemaCache
  PREFIX = 'schema-'

  module_function

  def enabled?
    Lighthouse::Config.schema_cache
  end

  def directory
    Lighthouse::Config.schema_cache_path ||
      if defined?(::Rails) && ::Rails.respond_to?(:root) && ::Rails.root
        ::Rails.root.join('tmp/cache/lighthouse').to_s
      else
        File.join(Dir.tmpdir, 'lighthouse-graphql')
      end
  end

  # The parsed document for `sdl` after manipulation. `build` turns the SDL
  # into the manipulated SDL string; it only runs on a cache miss.
  # `force:` caches even when the cache is off (warm!). `finalize:` (a callable
  # taking and returning the document) runs on the parsed document of a miss,
  # before it is cached.
  def document(sdl, force: false, finalize: nil, &build)
    return built(sdl, finalize, &build) unless force || enabled?

    path = File.join(directory.to_s, "#{PREFIX}#{key(sdl)}.bin")
    cached = read(path)
    return cached if cached

    built(sdl, finalize, &build).tap { |document| write(path, document) }
  end

  def built(sdl, finalize)
    document = parse(yield(sdl))
    finalize ? finalize.call(document) : document
  end

  def key(sdl)
    Digest::SHA256.hexdigest(
      [Lighthouse::GraphQL::VERSION, ::GraphQL::VERSION, RUBY_VERSION, sdl.to_s, fingerprint].join("\0")
    )
  end

  # Everything besides the SDL that changes the manipulated document.
  def fingerprint
    registry = Lighthouse::DirectiveRegistry.default
    manipulators = registry.sdl_manipulators.map { |manipulator| [manipulator.to_s, source_digest(manipulator)] }
    phase = { Lighthouse::GraphQL::ASTBuilder => :build, Lighthouse::GraphQL::Directives::GeneratedTypes => :columns_enum,
              Lighthouse::WhereConditions::Types => :define }
    phase.merge!(registry.arg_manipulator_classes.index_with(:manipulate_arg_definition))
    manipulators += phase.map { |manipulator, method_name| [manipulator.to_s, source_digest(manipulator, method_name)] }
    [
      registry.directive_definitions.sort,
      registry.type_definitions.sort,
      manipulators,
      Lighthouse::Config.pagination_default_count,
      Lighthouse::Support::Environment.current # @hide / @show
    ].inspect
  end

  # Build the schema document now (from Config.schema_path, unless given)
  # and return the cache file's path.
  def warm!(sdl = nil)
    sdl ||= Lighthouse::GraphQL::SchemaFactory.load_sdl
    Lighthouse::GraphQL::SchemaGenerator.build_document(sdl, force: true)
    File.join(directory.to_s, "#{PREFIX}#{key(sdl)}.bin")
  end

  def clear!
    Dir[File.join(directory.to_s, "#{PREFIX}*.bin")].each { |file| File.delete(file) }
  end

  # graphql-ruby's parser for schema definitions, as from_definition uses.
  def parse(sdl)
    parser = ::GraphQL.default_parser
    parser = parser::SchemaParser if parser.const_defined?(:SchemaParser, false)
    parser.parse(sdl)
  end

  # A missing, truncated or incompatible file is a miss, never an error.
  def read(path)
    return nil unless File.exist?(path)

    # Our own tmp/cache file, as Bootsnap reads its own; never anything a client sent.
    document = Marshal.load(File.binread(path)) # rubocop:disable Security/MarshalLoad
    document if document.is_a?(::GraphQL::Language::Nodes::Document)
  rescue StandardError
    nil
  end

  # Write atomically (a concurrent boot never reads half a file), then drop
  # the entries of earlier keys.
  def write(path, document)
    FileUtils.mkdir_p(File.dirname(path))
    temporary = "#{path}.#{Process.pid}.tmp"
    File.binwrite(temporary, Marshal.dump(document))
    File.rename(temporary, path)
    Dir[File.join(File.dirname(path), "#{PREFIX}*.bin")].each { |file| File.delete(file) unless file == path }
  rescue SystemCallError => e
    Lighthouse::Config.handle_error(e)
  end

  def source_digest(manipulator, method_name = :manipulate)
    file, = (manipulator.respond_to?(method_name) ? manipulator.method(method_name) : manipulator.instance_method(method_name)).source_location
    file && File.exist?(file) ? Digest::SHA256.file(file).hexdigest : nil
  rescue NameError
    nil
  end
end
