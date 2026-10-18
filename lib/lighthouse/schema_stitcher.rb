# frozen_string_literal: true

# Reads the schema from one entrypoint (Config.schema_path,
# graphql/schema.graphql by default) and pastes in the files it imports, as PHP
# Lighthouse's SchemaStitcher does:
#
#   type Query
#
#   #import user.graphql
#   #import blog/*.graphql
#
# An import names a path relative to the file it is in, and may be a glob.
# Imported files are read the same way, so they can import others. A file is
# read once: importing it again, or importing a file that imports it back,
# adds nothing. Only the files reached from the entrypoint are in the schema.
class Lighthouse::GraphQL::SchemaStitcher
  IMPORT = '#import '

  attr_reader :root_schema_path

  def initialize(root_schema_path)
    path = File.expand_path(root_schema_path.to_s)
    unless File.file?(path)
      raise Lighthouse::DefinitionError,
            "Failed to find a GraphQL schema file at #{path}. Set config.schema_path, or run bin/rails generate lighthouse:install."
    end

    @root_schema_path = File.realpath(path)
  end

  # The stitched schema: the entrypoint with every import replaced by the file's content.
  def schema_string
    gather(@root_schema_path, Set.new)
  end

  # Every file the schema is read from, the entrypoint first.
  def files
    visited = Set.new
    gather(@root_schema_path, visited)
    visited.to_a
  end

  private

  def gather(path, visited)
    return '' unless visited.add?(path)

    File.readlines(path, chomp: true).map { |line| import_line?(line) ? import(path, line, visited) : "#{line}\n" }.join
  end

  def import_line?(line)
    line.strip.start_with?(IMPORT)
  end

  def import(path, line, visited)
    name = line.strip.delete_prefix(IMPORT).strip
    import_path = File.join(File.dirname(path), name)
    return Dir.glob(import_path).map { |file| gather(File.realpath(file), visited) }.join if name.include?('*')

    raise Lighthouse::DefinitionError, "Did not find GraphQL schema import at #{import_path}." unless File.file?(import_path)

    gather(File.realpath(import_path), visited)
  end
end
