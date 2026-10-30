# frozen_string_literal: true

require 'set'

# What development learns of the schema on boot and on every reload. The
# schema is built and checked as `lighthouse:validate_schema` checks it
# (ValidateSchema, then every type), config.schema_output's file is rewritten
# when it changed, the persisted query manifest's operations are checked
# against it, and the outcome is logged:
#
#   [Lighthouse] ✓ AppSchema built in 84 ms: 42 types, 18 queries, 9 mutations
#   [Lighthouse]   + Query.search   + Post.excerpt   − Post.legacyTitle
#   [Lighthouse]   wrote schema.graphql
#
#   [Lighthouse] ✗ The schema does not build: Lighthouse::DefinitionError
#   [Lighthouse]   No directive found for `@can` on Query.a.
#   [Lighthouse]   The next GraphQL request raises it: save a fix to reload.
#
# Config.schema_log: nil (the default) logs in a development server (not in
# rake tasks or the console); true or false decide. schema_output is kept up
# to date in development either way.
module Lighthouse::GraphQL::SchemaReport
  # The most added, removed or invalid entries a line lists.
  LIST_LIMIT = 8

  module_function

  # The report's [level, text] lines, logged when Config.schema_log is on;
  # nil when there is nothing to do.
  def refresh(logger: default_logger)
    log = Lighthouse::Config.schema_log
    output = Lighthouse::GraphQL::SchemaPrinter.output if development?
    return unless log || output

    lines = report(output)
    log ? write_log(logger, lines) : warn_errors(lines)
    lines
  end

  def write_log(logger, lines)
    echo = console_not_attached?(logger)
    lines.each do |level, text|
      logger&.public_send(level, "[Lighthouse] #{text}")
      $stdout.puts("[Lighthouse] #{text}") if echo
    end
  end

  # `rails server` copies the log to the terminal once the app is loaded, so
  # the boot's report, logged while it loads, would reach only the log file.
  def console_not_attached?(logger)
    defined?(::Rails::Server) && logger && !::ActiveSupport::Logger.logger_outputs_to?(logger, $stdout, $stderr)
  end

  # schema_output without the log: a schema that does not build only warns, as before.
  def warn_errors(lines)
    lines.each { |level, text| warn("Lighthouse: #{text.strip}") if level == :error }
  end

  def report(output)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    schema = Lighthouse::GraphQL::SchemaPrinter.app_schema(output&.fetch(:schema, nil))
    Lighthouse::Events.dispatch(Lighthouse::Events::ValidateSchema.new(schema))
    printed = Lighthouse::GraphQL::SchemaPrinter.print(schema) # builds every type, as validate_schema does
    elapsed = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round

    types = fingerprint(printed)
    [[:info, "#{paint('✓', :green)} #{schema.name || 'The schema'} built in #{elapsed} ms: #{summary(schema, types)}"],
     *changes(schema, types), *written(schema, output, printed), *stale_operations(schema)]
  rescue StandardError => e
    [[:error, "#{paint('✗', :red)} The schema does not build: #{e.class}"],
     *e.message.lines.map { |line| [:error, "  #{line.chomp}"] },
     [:error, '  The next GraphQL request raises it: save a fix to reload.']]
  end

  # "42 types, 18 queries, 9 mutations"
  def summary(schema, types)
    roots = { 'queries' => schema.query, 'mutations' => schema.mutation, 'subscriptions' => schema.subscription }
    counts = roots.filter_map { |label, root| "#{root.fields.size} #{label}" if root }
    ["#{types.size} types", *counts].join(', ')
  end

  # What the reload added and removed: types, and the fields of the types kept.
  def changes(schema, current)
    previous = (@fingerprints ||= {})[schema.name]
    @fingerprints[schema.name] = current
    return [] unless previous
    return [[:info, '  unchanged']] if previous == current

    added = diff(current, previous).map { |name| "#{paint('+', :green)} #{name}" }
    removed = diff(previous, current).map { |name| "#{paint('−', :red)} #{name}" }
    [[:info, "  #{limited(added + removed).join('   ')}"]]
  end

  # { "Type" => Set of its field names } for the types clients see: those of
  # the printed schema, so none only Lighthouse's directives use.
  def fingerprint(printed)
    ::GraphQL.parse(printed).definitions.each_with_object({}) do |definition, types|
      next unless definition.respond_to?(:name) && !definition.is_a?(::GraphQL::Language::Nodes::DirectiveDefinition)

      types[definition.name] = (definition.respond_to?(:fields) ? definition.fields.map(&:name) : []).to_set
    end
  end

  # Types in `from` but not `other`, then fields of the types in both.
  def diff(from, other)
    (from.keys - other.keys) + (from.keys & other.keys).flat_map { |type| (from[type] - other[type]).map { |field| "#{type}.#{field}" } }
  end

  def written(schema, output, printed)
    return [] unless output

    content = output[:format] == 'sdl' ? printed : Lighthouse::GraphQL::SchemaPrinter.print(schema, format: output[:format])
    return [] unless Lighthouse::GraphQL::SchemaPrinter.write(output[:path], content)

    [[:info, "  wrote #{relative(output[:path])}"]]
  end

  # Manifest operations the schema no longer accepts, which shipped clients still send.
  def stale_operations(schema)
    return [] unless Lighthouse::Config.persisted_queries_manifest

    invalid = invalid_operations(schema)
    return [] if invalid.empty?

    [[:warn, "#{paint('!', :yellow)} Persisted operations the schema no longer accepts: #{invalid.size}"],
     *limited(invalid).map { |line| [:warn, "  #{line}"] }]
  rescue StandardError => e
    [[:warn, "#{paint('!', :yellow)} The persisted query manifest can not be read: #{e.message}"]]
  end

  def invalid_operations(schema)
    Lighthouse::GraphQL::PersistedQueries.manifest.filter_map do |hash, body|
      errors = schema.validate(body)
      "#{hash[0, 12]}…: #{errors.first.message}" if errors.any?
    end
  end

  def limited(items)
    items.size > LIST_LIMIT ? [*items.first(LIST_LIMIT), "and #{items.size - LIST_LIMIT} more"] : items
  end

  def relative(path)
    root = ::Rails.root.to_s if defined?(::Rails) && ::Rails.respond_to?(:root) && ::Rails.root
    root ? path.to_s.delete_prefix("#{root}/") : path.to_s
  end

  COLORS = { green: 32, red: 31, yellow: 33 }.freeze

  # ANSI colours, as Rails' own log lines have, when the app colorizes logging.
  def paint(text, color)
    colorize? ? "\e[1;#{COLORS.fetch(color)}m#{text}\e[0m" : text
  end

  def colorize?
    defined?(::Rails) && ::Rails.respond_to?(:application) && ::Rails.application&.config&.colorize_logging
  end

  def development? = defined?(::Rails) && ::Rails.respond_to?(:env) && ::Rails.env.development?

  def default_logger = (::Rails.logger if defined?(::Rails) && ::Rails.respond_to?(:logger))
end
