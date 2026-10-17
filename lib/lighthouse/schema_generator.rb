# frozen_string_literal: true

module Lighthouse::GraphQL::SchemaGenerator
  # Minimal fallback when SchemaImplementation isn't available.
  # Keep the same dispatch semantics so directive resolvers work.
  class FallbackImplementation
    attr_accessor :schema

    def call(type, field, obj, args, ctx)
      field_name = Lighthouse::GraphQL::GeneratedResolvers.field_name(field)
      resolver = generated_resolver(type, field_name)
      return Lighthouse::GraphQL::GeneratedResolvers.invoke(resolver, obj, args, ctx) if resolver
      return field.resolve_proc.call(obj, args, ctx) if field.respond_to?(:resolve_proc) && field.resolve_proc

      obj.respond_to?(field_name) ? obj.public_send(field_name) : nil
    end

    def resolve_type(_abstract_type, _obj, _ctx)
      nil
    end

    def coerce_input(_type, value, _ctx)
      value
    end

    def coerce_result(_type, value, _ctx)
      value
    end

    private

    def generated_resolver(type, field_name)
      owner = schema && schema.types[type.respond_to?(:graphql_name) ? type.graphql_name : type.name.to_s]
      method_name = Lighthouse::GraphQL::GeneratedResolvers.method_name(field_name)
      owner.method(method_name) if owner.respond_to?(method_name)
    end
  end

  module_function

  def build(sdl_string, **opts)
    # Decided on the app's SDL: once definitions are injected, every schema mentions it.
    uses_cache_control = sdl_string.to_s.gsub(/directive\s+@cacheControl/, '').include?('@cacheControl')
    # The manipulated document — from the schema cache when it is enabled
    # and fresh (see SchemaCache), else built now.
    document = build_document(sdl_string)
    impl = default_implementation
    schema = from_document(document, impl, opts)

    delegate_to_federation_sdl(schema)
    Lighthouse::GraphQL::GeneratedResolvers.install_dispatcher(schema)
    attach_schema(impl, schema)
    post_process(schema, impl, **opts)
    schema.trace_with(Lighthouse::Events::ExecutionTrace)

    # @cacheControl hints become the response's Cache-Control header,
    # computed per query from the fields it selects.
    schema.query_analyzer(Lighthouse::GraphQL::CacheControl::Analyzer) if uses_cache_control

    schema
  end

  # The runtime resolver graphql-ruby calls for every field: SchemaImplementation
  # (the library's, or the app's own) when loaded, else the minimal fallback.
  def default_implementation
    defined?(::SchemaImplementation) ? ::SchemaImplementation.new : FallbackImplementation.new
  end

  # Build using the provided base class so federation / custom schema behavior
  # is preserved through class hierarchy.
  # The document is handed over through `parser:`, graphql-ruby's public
  # hook, so it is not parsed again. Takes the options it uses out of `opts`;
  # the rest are post_process's.
  def from_document(document, impl, opts)
    base_types = opts.delete(:base_types) || {}
    using = opts.delete(:using) || {}
    schema_class = opts.delete(:schema_class) || ::GraphQL::Schema

    schema_class.from_definition('', parser: prebuilt_parser(document), default_resolve: impl,
                                     base_types: base_types, using: using)
  end

  # Make to_definition delegate to federation_sdl when available.
  def delegate_to_federation_sdl(schema)
    return unless schema.respond_to?(:federation_sdl)

    schema.define_singleton_method(:to_definition) do
      federation_sdl
    end
  end

  # Give the implementation object access to the built schema so its
  # runtime dispatcher can look up generated singleton resolvers.
  def attach_schema(impl, schema)
    impl.schema = schema if impl.respond_to?(:schema=)
  rescue StandardError
    # ignore
  end

  # A "parser" returning a document that is already parsed. A module, not
  # an object: graphql-ruby checks `defined?(parser::SchemaParser)`, which on
  # a plain object builds a TypeError message by inspecting it — the whole
  # document, quadratically slow on a large schema.
  def prebuilt_parser(document)
    Module.new { define_singleton_method(:parse) { |*| document } }
  end

  # The manipulated schema document for the app's SDL, from the schema cache
  # when it is enabled and fresh. The build events fire around the phases:
  # RegisterDirectiveNamespaces on every build (the cache key covers the
  # registered directives), BuildSchemaString and ManipulateAST only when the
  # document is built, i.e. on a cache miss.
  def build_document(sdl, force: false)
    Lighthouse::Events::SchemaBuild.register_directive_namespaces
    Lighthouse::GraphQL::SchemaCache.document(sdl, force: force, finalize: Lighthouse::Events::SchemaBuild.method(:manipulate_ast)) do |source|
      manipulate(Lighthouse::Events::SchemaBuild.schema_string(source))
    end
  end

  # The SDL as the schema is built from it: directive definitions injected
  # (so apps don't hand-declare Lighthouse's directives), then every
  # registered manipulator run (pagination types, whereConditions inputs, ...).
  def manipulate(sdl)
    augment_sdl_with_connections(inject_directive_definitions(sdl))
  end

  def post_process(schema, _impl, **_opts)
    root_kinds = { schema.query&.graphql_name => :queries, schema.mutation&.graphql_name => :mutations }.reject { |name, _| name.nil? }

    # Inspect types and fields for directives and attach generated resolvers
    schema.types.each_value do |type|
      next unless type.kind.object?

      # Apply object-level federation directives to generated types so the
      # Apollo Federation helper can detect entities and add _entities.
      Lighthouse::GraphQL::FederationDirectives.apply(type)
      type.fields.each_value { |field_def| process_field(type, field_def, root_kinds[type.graphql_name]) }
    end

    # @feature hides a field or type per query, through graphql-ruby's visibility.
    Lighthouse::GraphQL::FeatureDirective.apply(schema)

    # return schema for convenience
    schema
  end

  # A field's generated resolvers, then the runtime hooks that make
  # graphql-ruby reach them.
  def process_field(type, field_def, root_kind)
    return unless field_def.ast_node

    apply_field_resolvers(type, field_def, field_def.ast_node.directives || [], root_kind)
    Lighthouse::GraphQL::GeneratedResolvers.route_runtime_resolver(type, field_def)
    ensure_connection_extension(field_def)
  end

  # Ensure GraphQL-Ruby's ConnectionExtension is applied for SDL-built
  # connection fields so the runtime will wrap returned values into
  # Connection objects (populate_connection will be invoked).
  def ensure_connection_extension(field_def)
    return unless field_def.connection? && field_def.extensions.none?(::GraphQL::Schema::Field::ConnectionExtension)

    # Avoid adding the ConnectionExtension if pagination args were
    # already added by SDL augmentation (to prevent duplicate arg
    # collisions).
    return if (field_def.arguments || {}).then { |arguments| arguments.key?(:after) || arguments.key?('after') }

    field_def.extension(::GraphQL::Schema::Field::ConnectionExtension, call_after_define: false)
  rescue StandardError
    # ignore failures during post-processing
  end

  # A field's resolvers, installed in resolution order (see FieldResolverStack).
  def apply_field_resolvers(type, field_def, directives, root_kind)
    Lighthouse::GraphQL::FieldResolverStack.apply(type, field_def, directives, root_kind)
  end

  # Scan SDL string for list-typed fields that carry relationship directives
  # and produce Connection/Edge types where missing. This is a lightweight
  # transformation that mirrors Lighthouse behavior: clients can declare
  # `roles: [Role!]! @belongsToMany` and the builder will expose a
  # `RoleConnection` type and swap the field to return that connection.
  def augment_sdl_with_connections(sdl)
    # Drive SDL manipulation through the registry so each directive owns its
    # manipulation behavior and new manipulators can be added by registering
    # a class (no edits here).
    Lighthouse::DirectiveRegistry.default.manipulate_sdl(sdl)
  end

  # Prepend `directive @name(...) on ...` definitions for registered,
  # self-describing directives that the SDL uses but has not declared.
  # Already-declared directives are left untouched (no duplicates).
  def inject_directive_definitions(sdl)
    return sdl unless sdl.is_a?(String)

    missing = missing_directive_definitions(sdl)
    return sdl if missing.empty?

    definitions = missing.values + missing_type_definitions(sdl, missing.values).values
    "#{definitions.join("\n")}\n\n#{sdl}"
  end

  # Types the given directive definitions refer to (`CanAction`,
  # `ClearCacheIdSource`, ...) that the SDL does not define itself.
  def missing_type_definitions(sdl, directive_definitions, registry: Lighthouse::DirectiveRegistry.default)
    declared = sdl.to_s.scan(/^\s*(?:scalar|enum|input|type|interface|union)\s+(\w+)/).flatten.to_set
    text = directive_definitions.join("\n")
    registry.type_definitions.select { |name, _| declared.exclude?(name) && text.match?(/\b#{name}\b/) }
  end

  # The registry's directive definitions minus those the SDL declares itself.
  # Returns { "name" => "directive @name(...) on ..." }.
  def missing_directive_definitions(sdl, registry: Lighthouse::DirectiveRegistry.default)
    declared = sdl.to_s.scan(/directive\s+@(\w+)/).flatten.to_set
    registry.directive_definitions.except(*declared)
  end
end
