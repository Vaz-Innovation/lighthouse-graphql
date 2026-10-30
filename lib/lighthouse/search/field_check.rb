# frozen_string_literal: true

# What a field with @search must satisfy, checked when the schema is built
# (FieldResolverStack), where PHP Lighthouse fails when the query runs, or not at all:
#
# - `within:` is a string.
# - The field's model, when it can be told, is searchable by an adapter.
# - With an adapter outside the database (Searchkick), the field is an @all or
#   @paginate on a root field, or names its `model:`; and it has no `scopes:`,
#   @builder, @whereAuth or @orderBy(column:), which the engine cannot apply.
#   PHP Lighthouse drops them silently, so a search could return records the
#   user must not see. A relational adapter (pg_search) applies them.
class Lighthouse::Search::FieldCheck
  HINT = 'it needs searchkick or pg_search, or an adapter in Config.search'
  DATA_DIRECTIVES = %w[all paginate].freeze
  QUERY_DIRECTIVES = %w[builder whereAuth].freeze

  def self.check!(...) = new(...).check!

  def initialize(type, field_def, directives, root_kind)
    @type = type
    @field_def = field_def
    @directives = directives
    @root_kind = root_kind
  end

  def check!
    searches = Lighthouse::Search.directives(@field_def)
    return if searches.empty?

    searches.each { |path, directive| within_string!(path, directive) }
    model = model_class
    searches.each do |path, directive|
      index = Lighthouse::Support::DirectiveArgs.literal(directive, 'within')
      field_searched!(path, model, index) if model
    end
  end

  private

  def within_string!(path, directive)
    within = Lighthouse::Support::DirectiveArgs.literal(directive, 'within')
    return if within.nil? || within.is_a?(String)

    fail!(path, "expected the value of the `within` argument of @search to be a string, got: #{within.to_json}")
  end

  def field_searched!(path, model, index)
    adapter = adapter!(path, model, index)
    outside_database!(path, adapter) unless adapter.relational?
  end

  def adapter!(path, model, index)
    Lighthouse::Search.adapter_for(model, index) || fail!(path, "#{model.name} is not searchable (#{HINT})")
  end

  def outside_database!(path, adapter)
    name = adapter.class.name.demodulize
    fail!(path, "#{name} answers outside the database, so it needs @all or @paginate on a root field (or `model:`)") unless whole_table?
    dropped = dropped_constraints
    return if dropped.empty?

    fail!(path, "#{name} cannot apply #{dropped.join(', ')} (PHP Lighthouse drops them silently); " \
                'remove them, or search with a relational adapter (pg_search)')
  end

  # @all, or @paginate of the model's whole table (its own `model:`, not the parent's association).
  def whole_table?
    name = resolving_directive&.name
    return false unless DATA_DIRECTIVES.include?(name)

    name == 'all' || !@root_kind.nil? || !Lighthouse::Support::DirectiveArgs.literal(resolving_directive, 'model').nil?
  end

  # The field's own query constraints a search engine drops.
  def dropped_constraints
    scopes = Lighthouse::Support::DirectiveArgs.literal(resolving_directive, 'scopes') if resolving_directive
    registry = Lighthouse::DirectiveRegistry.default
    queries = @directives.select { |directive| QUERY_DIRECTIVES.include?(directive.name) || registry.field_builder_class(directive.name) }
    (scopes.present? ? ['`scopes:`'] : []) + queries.map { |directive| "@#{directive.name}" }
  end

  def resolving_directive
    return @resolving_directive if defined?(@resolving_directive)

    registry = Lighthouse::DirectiveRegistry.default
    @resolving_directive = @directives.find { |directive| registry.resolution_class(directive.name) && !registry.wrapper?(directive.name) }
  end

  # The field's model, as its resolving directive tells it (BaseDirectiveResolver#model_class);
  # nil when it cannot be told (a custom resolver).
  def model_class
    model = Lighthouse::Support::ModelResolver.constantize(Lighthouse::Support::ModelResolver.field_model_name(@field_def, resolving_directive))
    model if defined?(::ActiveRecord::Base) && model.is_a?(Class) && model < ::ActiveRecord::Base
  end

  def fail!(path, message)
    raise Lighthouse::DefinitionError, "@search on #{@type.graphql_name}.#{@field_def.name}(#{path}): #{message}."
  end
end
