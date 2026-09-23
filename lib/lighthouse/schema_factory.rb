# frozen_string_literal: true

module Lighthouse
  module GraphQL
    # Public entrypoint for building an executable schema from SDL.
    #
    # The returned value is a GraphQL-Ruby schema class (from `GraphQL::Schema.from_definition`)
    # intended to be subclassed by the application schema class.
    module SchemaFactory
      module_function

      def build_base_schema(sdl_folder: nil, sdl: nil, base_types: {}, schema_options: {}, **extra_options)
        # Absorb any extra keyword options (e.g. `federation: true`) into the
        # schema options bag so callers can pass schema-level flags directly
        # without the factory needing to enumerate every one.
        schema_options = extra_options.merge(schema_options)

        sdl_string =
          if sdl
            sdl
          else
            folder = sdl_folder || (Lighthouse::GraphQL::Config.sdl_folder if defined?(Lighthouse::GraphQL::Config))
            if folder && Dir.exist?(folder)
              Lighthouse::GraphQL::SDLLoader.load_from_folder(folder)
            else
              # fallback to apps/chatwoot/schema.graphql
              path = File.expand_path('../../schema.graphql', __dir__)
              File.read(path)
            end
          end

        schema_class = schema_options.delete(:schema_class)

        schema = Lighthouse::GraphQL::SchemaGenerator.build(
          sdl_string,
          base_types: base_types,
          schema_class: schema_class,
          **schema_options
        )

        schema
      end
    end
  end
end

