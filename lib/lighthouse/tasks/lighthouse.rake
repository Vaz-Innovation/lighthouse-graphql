# frozen_string_literal: true

namespace :lighthouse do
  desc 'Write schema-directives.graphql and programmatic-types.graphql for IDE support (OUTPUT=dir, default Rails.root)'
  task ide_helper: :environment do
    output_dir = ENV.fetch('OUTPUT') { Rails.root.to_s }
    Lighthouse::IdeHelper.write(output_dir: output_dir).each { |path| puts "Wrote #{path}" }
  end

  desc 'Print the schema clients see (SCHEMA=AppSchema FORMAT=sdl|json|federation; WRITE=1 or WRITE=path writes a file)'
  task print_schema: :environment do
    printer = Lighthouse::GraphQL::SchemaPrinter
    output = printer.output
    schema = printer.app_schema(ENV.fetch('SCHEMA', nil))
    format = ENV.fetch('FORMAT') { ENV['WRITE'] == '1' && output ? output[:format] : 'sdl' }
    content = printer.print(schema, format: format)
    if (write = ENV.fetch('WRITE', nil))
      path = write == '1' ? (output&.fetch(:path) || Rails.root.join(printer::FILENAMES.fetch(format))) : Rails.root.join(write)
      puts printer.write(path, content) ? "Wrote #{path}" : "#{path} is up to date"
    else
      puts content
    end
  rescue StandardError => e
    abort("#{schema || 'The schema'} can not be printed: #{e.message}")
  end

  namespace :schema_output do
    desc 'Fail when the file config.schema_output names is missing or out of date (for CI)'
    task verify: :environment do
      printer = Lighthouse::GraphQL::SchemaPrinter
      output = printer.output || abort('config.schema_output is not set.')
      abort("#{output[:path]} is out of date: run bin/rails lighthouse:print_schema WRITE=1") if printer.stale?(output)
      puts "#{output[:path]} is up to date."
    end
  end

  desc 'Build the schema cache in tmp/cache (for config.schema_cache; e.g. during a Docker build)'
  task cache: :environment do
    puts "Wrote #{Lighthouse::GraphQL::SchemaCache.warm!}"
  end

  desc 'Delete the schema cache'
  task clear_cache: :environment do
    Lighthouse::GraphQL::SchemaCache.clear!
    puts "Cleared #{Lighthouse::GraphQL::SchemaCache.directory}"
  end

  desc 'Build the schema, dispatch the ValidateSchema event and check graphql-ruby accepts it (SCHEMA=AppSchema)'
  task validate_schema: :environment do
    schema = Object.const_get(ENV.fetch('SCHEMA', 'AppSchema'))
    Lighthouse::Events.dispatch(Lighthouse::Events::ValidateSchema.new(schema))
    schema.to_definition # builds every type: unresolvable references and duplicate names raise
    puts "#{schema} is valid."
  rescue StandardError => e
    abort("#{schema || 'Schema'} is invalid: #{e.message}")
  end

  namespace :persisted_queries do
    desc 'Validate every operation of the persisted query manifest against the schema (SCHEMA=AppSchema)'
    task verify: :environment do
      schema = Object.const_get(ENV.fetch('SCHEMA', 'AppSchema'))
      failures = Lighthouse::GraphQL::PersistedQueries.manifest.filter_map do |hash, body|
        errors = schema.validate(body)
        "#{hash}: #{errors.map(&:message).join('; ')}" if errors.any?
      end
      abort("Operations the schema no longer accepts:\n#{failures.join("\n")}") if failures.any?
      puts "#{Lighthouse::GraphQL::PersistedQueries.manifest.size} persisted operations are valid."
    end
  end
end
