# frozen_string_literal: true

# Public entrypoint for building an executable schema from SDL.
#
# The returned value is a GraphQL-Ruby schema class (from `GraphQL::Schema.from_definition`)
# intended to be subclassed by the application schema class.
module Lighthouse::GraphQL::SchemaFactory
  module_function

  def build_base_schema(schema_path: nil, sdl: nil, base_types: {}, schema_options: {}, **extra_options)
    # Absorb any extra keyword options (e.g. `federation: true`) into the
    # schema options bag so callers can pass schema-level flags directly
    # without the factory needing to enumerate every one.
    schema_options = extra_options.merge(schema_options)

    sdl_string = sdl || load_sdl(schema_path)
    schema_class = schema_options.delete(:schema_class)

    Lighthouse::GraphQL::SchemaGenerator.build(
      sdl_string,
      base_types: base_types,
      schema_class: schema_class,
      **schema_options
    )
  end

  # The schema read from `schema_path` (default: Config.schema_path) and the
  # files it imports.
  def load_sdl(schema_path = nil)
    Lighthouse::GraphQL::SchemaStitcher.new(schema_path || Lighthouse::Config.schema_path).schema_string
  end
end
