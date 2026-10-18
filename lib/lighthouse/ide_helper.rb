# frozen_string_literal: true

require 'fileutils'

# Writes the SDL an IDE needs to understand a Lighthouse schema, mirroring PHP
# Lighthouse's `lighthouse:ide-helper`:
#
# - schema-directives.graphql — a definition for every registered directive
#   (built-in and app-registered) the app's SDL does not declare itself, so
#   the IDE can validate and autocomplete them.
# - programmatic-types.graphql — the types the manipulation phase generates
#   (Connection/Edge/Paginator types, PaginatorInfo, whereConditions inputs,
#   ...), which exist in the executable schema but in no .graphql file.
#
# Point your IDE's graphql-config at both files next to your own SDL. Run it
# with `bin/rails lighthouse:ide_helper`; in development, an app with a
# graphql.config.yml also gets them rewritten on boot and on every reload
# (Config.ide_helper).
#
# The IDE reads the three together as one schema, so no type may be in two of
# them: graphql-js (the VS Code and JetBrains plugins) rejects a type defined
# twice, even where graphql-ruby keeps the last definition.
module Lighthouse::IdeHelper
  DIRECTIVES_FILE = 'schema-directives.graphql'
  PROGRAMMATIC_TYPES_FILE = 'programmatic-types.graphql'

  TYPE_DEFINITIONS = [
    ::GraphQL::Language::Nodes::ObjectTypeDefinition,
    ::GraphQL::Language::Nodes::InputObjectTypeDefinition,
    ::GraphQL::Language::Nodes::InterfaceTypeDefinition,
    ::GraphQL::Language::Nodes::UnionTypeDefinition,
    ::GraphQL::Language::Nodes::EnumTypeDefinition,
    ::GraphQL::Language::Nodes::ScalarTypeDefinition
  ].freeze

  PLACEHOLDER_SCALAR = %("Placeholder for an argument type Lighthouse generates, e.g. with @whereConditions or @orderBy."\nscalar _)

  module_function

  # Writes both files into `output_dir` and returns their paths. A file whose
  # content has not changed is left alone, so the IDE does not reload for nothing.
  #
  # A schema that does not build (a type defined twice, half-written, ...)
  # still gets its directives, and keeps the programmatic types it had, or
  # gets the `_` placeholder alone: the IDE never loses a type it was given.
  def write(output_dir:, schema_path: Lighthouse::Config.schema_path, registry: Lighthouse::DirectiveRegistry.default)
    sdl = ide_sdl(schema_path)
    directives = directives_sdl(sdl, registry: registry)

    FileUtils.mkdir_p(output_dir.to_s)
    directives_path = write_file(output_dir, DIRECTIVES_FILE, directives)
    types_path = File.join(output_dir.to_s, PROGRAMMATIC_TYPES_FILE)
    begin
      write_file(output_dir, PROGRAMMATIC_TYPES_FILE, programmatic_types_sdl(sdl, registry: registry, directives: directives))
    rescue StandardError => e
      warn("Lighthouse: #{PROGRAMMATIC_TYPES_FILE} kept as it was, the schema does not build: #{e.message}")
      write_file(output_dir, PROGRAMMATIC_TYPES_FILE, placeholder_only(sdl)) unless File.exist?(types_path)
    end
    [directives_path, types_path]
  end

  # The schema as the IDE reads it: the entrypoint and its imports, or, when
  # they do not load, every .graphql file under the entrypoint's folder.
  def ide_sdl(schema_path)
    return '' unless schema_path

    return Lighthouse::GraphQL::SchemaFactory.load_sdl(schema_path) if File.file?(schema_path.to_s)

    raise Lighthouse::DefinitionError, "no schema at #{schema_path}"
  rescue Lighthouse::DefinitionError
    Dir[File.join(File.dirname(schema_path.to_s), '**', '*.graphql')].map { |file| File.read(file) }.join("\n")
  end

  def write_file(output_dir, name, content)
    path = File.join(output_dir.to_s, name)
    File.write(path, content) unless File.exist?(path) && File.read(path) == content
    path
  end

  def placeholder_only(sdl)
    declared = sdl.to_s.match?(/^\s*scalar\s+_\b/) ? Set['_'] : Set.new
    render('The schema does not build: only the `_` placeholder is declared until it does.',
           undeclared_placeholder?(sdl, declared) ? [PLACEHOLDER_SCALAR] : [])
  end

  # Config.ide_helper's refresh: the files in the Rails app's root, when the
  # schema loads. A schema that does not is the next request's error to raise;
  # here it only warns.
  def refresh(output_dir: ::Rails.root)
    return [] unless Lighthouse::Config.ide_helper

    write(output_dir: output_dir)
  rescue StandardError => e
    warn("Lighthouse: the IDE helper files were not refreshed: #{e.message}")
    []
  end

  def directives_sdl(sdl = '', registry: Lighthouse::DirectiveRegistry.default)
    generator = Lighthouse::GraphQL::SchemaGenerator
    definitions = generator.missing_directive_definitions(sdl, registry: registry).sort.map { |_, definition| definition }
    types = generator.missing_type_definitions(sdl, definitions, registry: registry).sort.map { |_, definition| definition }
    render(
      'Directive definitions contributed by Lighthouse and the directives your app registered.',
      definitions + types
    )
  end

  # `directives`: the schema-directives.graphql written next to it, whose types
  # (`CanAction`, `Mixed`, ...) some manipulators inject too and are left out here.
  def programmatic_types_sdl(sdl, registry: Lighthouse::DirectiveRegistry.default, directives: directives_sdl(sdl, registry: registry))
    declared = type_names(sdl) | type_names(directives)
    generated_sdl = generated_types(sdl, declared, registry).sort_by(&:name).map(&:to_query_string)
    generated_sdl.unshift(PLACEHOLDER_SCALAR) if undeclared_placeholder?(sdl, declared)

    render(
      'Types the manipulation phase generates (Connection/Paginator types, whereConditions inputs, ...).',
      generated_sdl
    )
  end

  # The types of the manipulated schema that neither the SDL nor the directives file defines.
  def generated_types(sdl, declared, registry)
    manipulated = Lighthouse::GraphQL::ASTBuilder.build(Lighthouse::GraphQL::SchemaGenerator.inject_directive_definitions(sdl), registry: registry)
    parse(manipulated).definitions.select do |definition|
      type_definition?(definition) && declared.exclude?(definition.name) && definition.name != '_'
    end
  end

  # The manipulation phase replaces the `_` placeholder (`where: _ @whereConditions`,
  # `orderBy: _ @orderBy`), but the IDE reads the SDL as written, so it needs
  # the placeholder declared.
  def undeclared_placeholder?(sdl, declared)
    sdl.to_s.match?(/:\s*\[?\s*_\b/) && declared.exclude?('_')
  end

  def type_names(sdl)
    parse(sdl).definitions.filter_map { |definition| definition.name if type_definition?(definition) }.to_set
  end

  def type_definition?(definition)
    TYPE_DEFINITIONS.any? { |kind| definition.is_a?(kind) }
  end

  def parse(sdl)
    ::GraphQL::Language::Parser.parse(sdl.to_s)
  end

  def render(summary, definitions)
    header = <<~GRAPHQL
      # Generated by `bin/rails lighthouse:ide_helper` — do not edit; rerun it after changing your schema.
      # #{summary}
    GRAPHQL
    "#{header}\n#{definitions.join("\n\n")}\n"
  end
end
