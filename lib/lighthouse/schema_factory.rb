# frozen_string_literal: true

# Public entrypoint for building an executable schema from SDL.
#
# The returned value is a GraphQL-Ruby schema class (from `GraphQL::Schema.from_definition`)
# intended to be subclassed by the application schema class.
module Lighthouse::GraphQL::SchemaFactory
  module_function

  def build_base_schema(sdl_folder: nil, sdl: nil, base_types: {}, schema_options: {}, **extra_options)
    # Absorb any extra keyword options (e.g. `federation: true`) into the
    # schema options bag so callers can pass schema-level flags directly
    # without the factory needing to enumerate every one.
    schema_options = extra_options.merge(schema_options)

    sdl_string = sdl || load_sdl(sdl_folder)
    schema_class = schema_options.delete(:schema_class)

    Lighthouse::GraphQL::SchemaGenerator.build(
      sdl_string,
      base_types: base_types,
      schema_class: schema_class,
      **schema_options
    )
  end

  # The SDL in `sdl_folder` (default: Config.sdl_folder), or the bundled
  # schema.graphql when there is no such folder.
  def load_sdl(sdl_folder)
    folder = sdl_folder || (Lighthouse::GraphQL::Config.sdl_folder if defined?(Lighthouse::GraphQL::Config))
    return Lighthouse::GraphQL::SDLLoader.load_from_folder(folder) if folder && Dir.exist?(folder)

    File.read(File.expand_path('../../schema.graphql', __dir__))
  end
end
