# frozen_string_literal: true

# What a field with @search must satisfy, checked when the schema is built
# (FieldResolverStack), where PHP Lighthouse fails when the query runs, or not at all:
#
# - `within:` is a string.
# - Something applies the search: a resolver that runs the field's argument
#   filters (`applies_search?`, declared by each resolver class), or the app's
#   own code (a convention class, a type class's method, @field), which reads it
#   through resolve_info.enhance_builder. Never the default reader, which would
#   ignore it.
# - The field's model, when it can be told, is searchable by an adapter.
# - With an adapter outside the database (Searchkick), the resolver takes the
#   records the engine answers with (`takes_search_results?`: @all, @paginate of
#   the model's whole table, the app's own code); and the field has no `scopes:`,
#   @builder, @whereAuth or @orderBy(column:), which the engine cannot apply.
#   PHP Lighthouse drops them silently, so a search could return records the
#   user must not see. A relational adapter (pg_search) applies them.
# - An @canQuery, which runs the search to check the records it finds, searches
#   a searchable model, and without `scopes:` when the engine cannot apply them.
class Lighthouse::Search::FieldCheck
  HINT = 'it needs searchkick or pg_search, or an adapter in Config.search'
  QUERY_DIRECTIVES = %w[builder whereAuth].freeze

  def self.check!(...) = new(...).check!

  # `type_class`: the type's class (Types::PostType), whose methods resolve its fields with no resolving directive.
  def initialize(type, field_def, directives, root_kind, type_class: nil)
    @type = type
    @field_def = field_def
    @directives = directives
    @root_kind = root_kind
    @type_class = type_class
  end

  def check!
    searches = Lighthouse::Search.directives(@field_def)
    return if searches.empty?

    searches.each { |path, directive| within_string!(path, directive) }
    applied!(searches.first.first)
    model = model_class
    searches.each do |path, directive|
      index = Lighthouse::Support::DirectiveArgs.literal(directive, 'within')
      field_searched!(path, model, index) if model
      can_queries.each { |can_query| can_query_searched!(path, can_query, index) }
    end
  end

  private

  def within_string!(path, directive)
    within = Lighthouse::Support::DirectiveArgs.literal(directive, 'within')
    return if within.nil? || within.is_a?(String)

    fail!(path, "expected the value of the `within` argument of @search to be a string, got: #{within.to_json}")
  end

  def applied!(path)
    return if own_code? || resolver_class&.applies_search?

    fail!(path, "nothing applies the search: #{resolver_name} runs no argument filters. Resolve the field with a directive " \
                'that does (@all, @paginate, @find, a relationship, ...), or a class of your own that calls resolve_info.enhance_builder')
  end

  def resolver_name
    resolving_directive ? "@#{resolving_directive.name}" : "graphql-ruby's default reader, which reads #{@field_def.name} off the parent,"
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
    unless own_code? || resolver_class.takes_search_results?(@type, @field_def, resolving_directive, @root_kind)
      fail!(path, "#{name} answers outside the database, so it needs @all, @paginate of the model's whole table (on a root field, " \
                  'with its own `model:`, or where the parent has no association of its name), or a resolver of your own ' \
                  '(which reads the search through resolve_info.enhance_builder)')
    end
    dropped = dropped_constraints
    unless dropped.empty?
      fail!(path, "#{name} cannot apply #{dropped.join(', ')} (PHP Lighthouse drops them silently); " \
                  'remove them, or search with a relational adapter (pg_search)')
    end
    defaulted_constraints.each do |constraint|
      fail!(path, "#{name} cannot apply #{constraint}, whose default value would apply to every search (PHP Lighthouse " \
                  'fails every search); remove the default, or search with a relational adapter (pg_search)')
    end
  end

  # "@where on minId" for every argument or input field with a default value, and
  # a directive an engine cannot apply: graphql-ruby fills the default in, as PHP
  # Lighthouse's arguments hold it, so the directive would apply to every search.
  def defaulted_constraints
    registry = Lighthouse::DirectiveRegistry.default
    walk = Lighthouse::Support::ArgumentWalk
    walk.definitions(@field_def.arguments).select { |_path, argument| argument.default_value? }.flat_map do |path, argument|
      walk.directives(argument).filter_map do |directive|
        builder = registry.arg_builder_class(directive.name)
        next if builder.nil? || directive.name == 'search' || Lighthouse::Search::Enhancer.compatible?(builder)

        "@#{directive.name} on #{path}"
      end
    end
  end

  # @canQuery checks each record the search finds (CanQueryDirectiveResolver): its
  # model must be searchable, and its `scopes:` applied by the engine.
  def can_query_searched!(path, can_query, index)
    model = model_of(Lighthouse::Support::ModelResolver.field_model_name(@field_def, can_query)) || return
    adapter = adapter!(path, model, index)
    return if adapter.relational? || Lighthouse::Support::DirectiveArgs.literal(can_query, 'scopes').blank?

    fail!(path, "#{adapter.class.name.demodulize} cannot apply the `scopes:` of @canQuery, which checks the records the search finds " \
                '(PHP Lighthouse drops them silently); remove them, or search with a relational adapter (pg_search)')
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

    @resolving_directive = Lighthouse::GraphQL::FieldResolverStack.resolving_directive(@directives)
  end

  # The resolver class of the field's resolving directive; nil without one.
  def resolver_class
    resolving_directive && Lighthouse::DirectiveRegistry.default.resolution_class(resolving_directive.name)
  end

  # Is the field resolved by the app's own code, which reads the search through enhance_builder?
  def own_code?
    resolving_directive.nil? && Lighthouse::GraphQL::FieldResolverStack.own_resolver?(@field_def, @root_kind, @type_class)
  end

  def can_queries = @directives.select { |directive| directive.name == 'canQuery' }

  # The field's model, as its resolving directive tells it (BaseDirectiveResolver#model_class),
  # else the model of the parent's association it reads (@count(relation:)); nil when it cannot
  # be told.
  def model_class
    model_of(Lighthouse::Support::ModelResolver.field_model_name(@field_def, resolving_directive)) || association_model
  end

  def association_model
    return if @root_kind

    parent = model_of(Lighthouse::GraphQL::Directives::ModelDirective.model_for(@type)) || return
    name = Lighthouse::Support::DirectiveArgs.literal(resolving_directive, 'relation') || Lighthouse::Support::Naming.attribute(@field_def.name)
    model_of(parent.reflect_on_association(name.to_sym)&.klass)
  rescue ArgumentError, NameError # a polymorphic association, or one whose class does not exist
    nil
  end

  def model_of(name_or_class) = Lighthouse::Support::ModelResolver.model_class(name_or_class)

  def fail!(path, message)
    raise Lighthouse::DefinitionError, "@search on #{@type.graphql_name}.#{@field_def.name}(#{path}): #{message}."
  end
end
