# frozen_string_literal: true

module Lighthouse
  module GraphQL
    module SchemaGenerator
      module_function

      def build(sdl_string, **opts)
        # Contribute SDL definitions for any registered directive the schema uses
        # but hasn't declared, so the app doesn't hand-declare every directive.
        sdl_string = inject_directive_definitions(sdl_string)
        # Augment SDL: convert list-typed fields with relationship directives
        # (e.g. `roles: [Role!]! @belongsToMany`) into connection types
        # (`roles: RoleConnection!`) and generate missing Connection/Edge types.
        sdl_string = augment_sdl_with_connections(sdl_string)
        impl =
          if defined?(::SchemaImplementation)
            ::SchemaImplementation.new
          else
            # Minimal fallback when SchemaImplementation isn't available.
            # Keep the same dispatch semantics so directive resolvers work.
            Class.new do
              attr_accessor :schema

              def call(type, field, obj, args, ctx)
                field_name = field.respond_to?(:graphql_name) ? field.graphql_name.to_s : field.name.to_s
                owner = schema && schema.types[type.respond_to?(:graphql_name) ? type.graphql_name : type.name.to_s]

                if owner && owner.respond_to?("resolve_field_#{field_name}")
                  resolver = owner.method("resolve_field_#{field_name}")
                  param_count = resolver.parameters.length
                  return resolver.call(obj, args) if param_count == 2

                  return resolver.call(obj, args, ctx)
                end

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
            end.new
          end

        final_sdl = sdl_string
        base_types = opts.delete(:base_types) || {}
        using = opts.delete(:using) || {}
        schema_class = opts.delete(:schema_class) || ::GraphQL::Schema

        # Build using the provided base class so federation / custom schema behavior
        # is preserved through class hierarchy.
        schema = schema_class.from_definition(final_sdl, default_resolve: impl, base_types: base_types, using: using)

        # Make to_definition delegate to federation_sdl when available.
        if schema.respond_to?(:federation_sdl)
          schema.define_singleton_method(:to_definition) do
            federation_sdl
          end
        end
        # GraphQL-Ruby caches field resolution procs during schema build; rather
        # than trying to override per-field `resolve_<field>` methods post-hoc,
        # we install a single dispatcher here that prefers our generated
        # `resolve_field_<name>` singletons.
        if schema.respond_to?(:definition_default_resolve=) && schema.respond_to?(:definition_default_resolve)
          previous_default = schema.definition_default_resolve
          schema.definition_default_resolve = proc do |type, field, obj, arguments, ctx|
            owner =
              if type.respond_to?(:graphql_name)
                schema.types[type.graphql_name]
              elsif type.respond_to?(:name)
                schema.types[type.name.to_s]
              end

            field_name = field.respond_to?(:graphql_name) ? field.graphql_name.to_s : field.name.to_s

            if owner && owner.respond_to?("resolve_field_#{field_name}")
              resolver = owner.method("resolve_field_#{field_name}")
              source_file, = resolver.source_location
              # GraphQL-Ruby's SDL builder also defines `resolve_field_*` methods
              # internally. Only invoke ours (defined under `lib/lighthouse/`),
              # otherwise we may call an internal resolver with the wrong arity.
              if source_file && source_file.include?('/lib/lighthouse/')
                param_count = resolver.parameters.length
                next resolver.call(obj, arguments) if param_count == 2

                next resolver.call(obj, arguments, ctx)
              end
            end

            previous_default.call(type, field, obj, arguments, ctx)
          end
        end

        # Give the implementation object access to the built schema so its
        # runtime dispatcher can look up generated singleton resolvers.
        begin
          impl.schema = schema if impl.respond_to?(:schema=)
        rescue StandardError
          # ignore
        end

        post_process(schema, impl, **opts)

        schema
      end

      def post_process(schema, impl, **_opts)
        # Inspect types and fields for directives and attach generated resolvers
        schema.types.each_value do |t|
          next unless t.kind.object?

          # Apply object-level federation directives to generated types so the
          # Apollo Federation helper can detect entities and add _entities.
          if t.ast_node && t.respond_to?(:key)
            t.ast_node.directives.each do |dnode|
              case dnode.name
              when 'key'
                arg = dnode.arguments.find { |a| a.name == 'fields' }
                t.key(fields: arg.value) if arg && arg.respond_to?(:value)

                # Setup federation resolve_reference: prefer a custom resolver
                # registered with ReferenceResolver, but fall back to the base
                # type's own resolve_reference (e.g. BaseObject's default model
                # lookup) so direct-model entities resolve without a custom
                # handler. Capture the inherited implementation before shadowing.
                default_resolve_reference =
                  t.respond_to?(:resolve_reference) ? t.method(:resolve_reference) : nil

                t.define_singleton_method(:resolve_reference) do |reference, context|
                  resolved = ::Lighthouse::ReferenceResolver.resolve(t.graphql_name, reference, context)
                  next resolved unless resolved.nil?

                  default_resolve_reference ? default_resolve_reference.call(reference, context) : nil
                end
              when 'extends'
                t.extend_type if t.respond_to?(:extend_type)
              when 'shareable'
                t.shareable if t.respond_to?(:shareable)
              when 'inaccessible'
                t.inaccessible if t.respond_to?(:inaccessible)
              when 'interfaceObject'
                t.interface_object if t.respond_to?(:interface_object)
              end
            end
          end

          t.fields.each do |fname, field_def|
            next unless field_def.ast_node

            directives = field_def.ast_node.directives || []
            registry = Lighthouse::DirectiveRegistry.default
            # Apply wrapping directives in resolution order: data resolvers first
            # (innermost), then @can (wraps to authorize the result), then guards
            # (outermost, so authentication runs before anything else).
            sorted = directives.sort_by { |d| registry.resolution_order(d.name) }

            # Dispatch each directive to its registered resolver class. The
            # registry replaces the previous hardcoded `case dnode.name` so that
            # adding a directive is "register a class", not "edit the generator".
            sorted.each do |dnode|
              resolver_class = registry.resolution_class(dnode.name)
              next unless resolver_class

              resolver_class.new(field_def, t, dnode).define_resolver(t)
            end

            # GraphQL-Ruby's SDL builder defines `resolve_<field>` methods that call
            # the schema's `definition_default_resolve`. Override `resolve_<field>`
            # to delegate to our generated `resolve_field_<field>` when present, so
            # runtime resolution consistently reaches our directive resolvers.
            begin
              method_name = "resolve_field_#{field_def.name}"
              runtime_name = "resolve_#{field_def.name}"
              if t.respond_to?(method_name)
                t.define_singleton_method(runtime_name) do |obj, arguments, ctx|
                  public_send(method_name, obj, arguments, ctx)
                end
              end
            rescue StandardError
              # ignore override failures
            end

            # Ensure GraphQL-Ruby's ConnectionExtension is applied for SDL-built
            # connection fields so the runtime will wrap returned values into
            # Connection objects (populate_connection will be invoked).
            begin
              # Avoid adding the ConnectionExtension if pagination args were
              # already added by SDL augmentation (to prevent duplicate arg
              # collisions).
              if field_def.connection? && !(field_def.extensions.any? do |e|
                e.is_a?(::GraphQL::Schema::Field::ConnectionExtension)
              end) && !((field_def.arguments || {}).key?(:after) || (field_def.arguments || {}).key?('after'))
                field_def.extension(::GraphQL::Schema::Field::ConnectionExtension,
                                    call_after_define: false)
              end
            rescue StandardError
              # ignore failures during post-processing
            end
          end
        end

        # return schema for convenience
        schema
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

        "#{missing.values.join("\n")}\n\n#{sdl}"
      end

      # The registry's directive definitions minus those the SDL declares itself.
      # Returns { "name" => "directive @name(...) on ..." }.
      def missing_directive_definitions(sdl, registry: Lighthouse::DirectiveRegistry.default)
        declared = sdl.to_s.scan(/directive\s+@(\w+)/).flatten.to_set
        registry.directive_definitions.reject { |name, _| declared.include?(name) }
      end
    end
  end
end
