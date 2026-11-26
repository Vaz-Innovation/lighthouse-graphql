# frozen_string_literal: true

# Helpers exposed to every example for building schemas from inline SDL.
module SchemaBuilders
  # `dataloader: true` enables GraphQL::Dataloader, as app schemas do.
  def build_schema(sdl, federation: false, base_types: {}, dataloader: false)
    Lighthouse::GraphQL::SchemaFactory.build_base_schema(
      sdl: sdl,
      base_types: base_types,
      federation: federation,
      schema_options: dataloader ? { using: { GraphQL::Dataloader => {} } } : {}
    )
  end

  # A Federation 2 subgraph: `sdl` after the link to the spec, importing `imports`.
  def build_subgraph(sdl, imports: %w[@key @shareable @external @requires @provides @override @inaccessible @tag @interfaceObject],
                     version: '2.9', **options)
    link = %(extend schema @link(url: "https://specs.apollo.dev/federation/v#{version}", import: #{imports.to_json}))
    build_schema("#{link}\n#{sdl}", **options)
  end
end

RSpec.configure do |config|
  config.include SchemaBuilders
end
