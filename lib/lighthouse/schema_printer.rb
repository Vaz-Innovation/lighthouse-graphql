# frozen_string_literal: true

require 'json'

# The schema as clients see it (Lighthouse's directives are not in it, see
# ServerDirectives), printed as PHP Lighthouse's `lighthouse:print-schema`
# prints it: SDL, the introspection result as JSON (`json`), or a subgraph's
# SDL with its federation directives (`federation`). The SDL comes from
# graphql-ruby's printer (to_definition answers a federated schema with its
# subgraph SDL), which orders types, fields, arguments and values
# alphabetically: what PHP Lighthouse's `--sort` asks webonyx for.
#
# Config.schema_output keeps a file of it in development, as NestJS's
# autoSchemaFile does: rewritten on boot and on every reload (SchemaReport),
# only when it changed, so a codegen watching it runs only then.
#
#   Lighthouse.configure { |config| config.schema_output = 'schema.graphql' }
#   Lighthouse.configure { |config| config.schema_output = { path: 'schema.json', schema: 'Admin::Schema' } }
module Lighthouse::GraphQL::SchemaPrinter
  FORMATS = %w[sdl json federation].freeze

  # PHP Lighthouse's file names, for `lighthouse:print_schema WRITE=1` with no schema_output.
  FILENAMES = {
    'sdl' => 'lighthouse-schema.graphql',
    'json' => 'lighthouse-schema.json',
    'federation' => 'lighthouse-schema-federation.graphql'
  }.freeze

  module_function

  def print(schema, format: 'sdl')
    format = format.to_s
    raise ArgumentError, "Unknown schema format #{format.inspect}, expected #{FORMATS.join(', ')}." unless FORMATS.include?(format)

    case format
    when 'sdl' then ::GraphQL::Schema::Printer.print_schema(schema)
    when 'json' then "#{JSON.pretty_generate(schema.as_json.fetch('data'))}\n"
    else federation(schema)
    end
  end

  def federation(schema)
    raise ArgumentError, 'The federation format needs a federated schema (federation: true).' unless schema.respond_to?(:federation_sdl)

    "#{schema.federation_sdl.chomp}\n"
  end

  # The app's schema class: `name`, else schema_output's `schema:`, else
  # graphql-ruby's install's name (`<App>Schema`), else AppSchema.
  def app_schema(name = nil)
    candidates = [name, output&.fetch(:schema, nil), default_schema_name, 'AppSchema'].compact.uniq
    candidates.each do |candidate|
      schema = candidate.to_s.safe_constantize
      return schema if schema
    end
    raise Lighthouse::DefinitionError, "No schema class #{candidates.join(' or ')}: name it with SCHEMA=, or schema_output's schema:."
  end

  def default_schema_name
    return unless defined?(::Rails) && ::Rails.respond_to?(:application) && ::Rails.application

    "#{::Rails.application.class.module_parent_name}Schema"
  end

  # Config.schema_output as { path:, schema:, format: }, the path
  # absolute (under Rails.root) and the format from its extension; nil when unset.
  def output
    setting = Lighthouse::Config.schema_output
    return if setting.nil?

    options = setting.is_a?(Hash) ? setting.symbolize_keys : { path: setting }
    path = Pathname(options.fetch(:path))
    path = ::Rails.root.join(path) if path.relative? && defined?(::Rails) && ::Rails.root
    { path: path, schema: options[:schema], format: path.extname == '.json' ? 'json' : 'sdl' }
  end

  # The schema as schema_output asks for it.
  def output_content(setting = output)
    print(app_schema(setting[:schema]), format: setting[:format])
  end

  # Writes `content` at `path` unless it holds it already, through a
  # temporary file renamed over it, so a watcher never reads half a schema.
  # True when it wrote.
  def write(path, content)
    path = Pathname(path)
    return false if path.file? && path.read == content

    path.dirname.mkpath
    temporary = path.dirname.join(".#{path.basename}.#{Process.pid}.tmp")
    temporary.write(content)
    File.rename(temporary, path)
    true
  end

  # Is the file at schema_output missing or out of date?
  def stale?(setting = output)
    !(setting[:path].file? && setting[:path].read == output_content(setting))
  end
end
