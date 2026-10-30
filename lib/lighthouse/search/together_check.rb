# frozen_string_literal: true

# A field of a union or an interface (with @all or @paginate, and no `model:`) whose @search
# searches the models of its types together, in one search, checked when the schema is built
# (SchemaGenerator, before FieldCheck, which leaves the field to it), as FieldCheck checks a
# field of one model. It keeps the models for the field's resolvers (Search.together!).
#
# Each type is a model's (@model, or its name), one engine searches them all
# (`adapter_together`, `together_error`), the @search argument is a top-level, non-null one,
# with no `within:`, on a root field; and nothing a model would apply alone, but the engine
# across them cannot, is asked for: `scopes:`, @builder, @whereAuth, @orderBy(column:),
# @trashed, a default value the engine cannot apply, an @canQuery's `scopes:`.
class Lighthouse::Search::TogetherCheck < Lighthouse::Search::FieldCheck
  # Every field of the schema's object types (`root_kinds`: SchemaGenerator#root_kinds).
  def self.check_schema!(schema, root_kinds)
    schema.types.each_value do |type|
      next unless type.kind.object?

      type.fields.each_value { |field_def| check!(schema, type, field_def, root_kinds[type.graphql_name]) if field_def.owner == type }
    end
  end

  def self.check!(schema, type, field_def, root_kind)
    return unless field_def.ast_node

    new(schema, type, field_def, root_kind).check!
  end

  def initialize(schema, type, field_def, root_kind)
    super(type, field_def, field_def.ast_node.directives || [], root_kind)
    @schema = schema
  end

  def check!
    searches = Lighthouse::Search.directives(@field_def)
    together!(searches) if searches.any? && together?
  end

  private

  # Does the field search the models of a union's or an interface's types together? One that a
  # data directive resolves without a `model:` of its own.
  def together?
    !resolving_directive.nil? && returned&.kind&.abstract? &&
      Lighthouse::Support::DirectiveArgs.literal(resolving_directive, 'model').nil?
  end

  # The type of what the field returns: of its items, for a paginated field (`PostPaginator`'s Post).
  def returned
    type = @field_def.type.unwrap
    return type unless resolving_directive.name == 'paginate'

    @schema.get_type(type.graphql_name.sub(Lighthouse::Support::ModelResolver::PAGINATION_SUFFIX, ''))
  end

  def together!(searches)
    path = searches.first.first
    searches.each { |each_path, directive| within_string!(each_path, directive) }
    applied!(path)
    together_field!(path, searches)
    models = together_models(path)
    adapter = together_adapter!(path, models)
    together_constraints!(path, adapter)
    can_queries.each { |can_query| together_can_query!(path, can_query) }
    Lighthouse::Search.together!(@field_def, models)
  end

  # On a root field, with @all or @paginate, and one @search: a top-level, non-null argument
  # (with no models to list, a field of several models answers a search, always), with no `within:`.
  def together_field!(path, searches)
    unless @root_kind && %w[all paginate].include?(resolving_directive.name)
      fail!(path, "#{abstract_name} has several models, which only @all or @paginate on a root field search together " \
                  '(or give the directive the `model:` it searches)')
    end
    one_search!(path, searches)
    return if Lighthouse::Support::DirectiveArgs.literal(searches.first.last, 'within').nil?

    fail!(path, "`within:` names one model's index or scope, and #{abstract_name}'s models are searched together")
  end

  def one_search!(path, searches)
    return if searches.size == 1 && @field_def.arguments[path]&.type&.non_null?

    fail!(path, "a field that searches #{abstract_name}'s models together needs its search: one @search, on a non-null argument " \
                '(`search: String!`), which there is no table to list without')
  end

  # The models of the union's or the interface's object types: each must be a model's.
  def together_models(path)
    types = @schema.possible_types(returned).sort_by(&:graphql_name)
    types.map do |type|
      Lighthouse::GraphQL::Directives::ModelDirective.model_for(type) ||
        fail!(path, "#{abstract_name}'s type #{type.graphql_name} is no model's: give it @model(class:), or remove it")
    end
  end

  def together_adapter!(path, models)
    adapter = Lighthouse::Search.adapter_together(models) || no_engine!(path, models)
    models.each do |model|
      error = adapter.together_error(model)
      fail!(path, error) if error
    end
    adapter
  end

  # What one model's search would apply, and a search of several cannot: the field's own query
  # directives and `scopes:`, @trashed (each model has its own soft-delete column) and default
  # values the engine cannot apply.
  def together_constraints!(path, adapter)
    name = adapter.class.name.demodulize
    dropped = dropped_constraints
    fail!(path, "#{name} cannot apply #{dropped.join(', ')} to models searched together; remove them") unless dropped.empty?
    trashed = Lighthouse::Support::ArgumentWalk.field_definitions(@field_def).find do |_, argument|
      Lighthouse::Support::ArgumentWalk.directives(argument).any? { |directive| directive.name == 'trashed' }
    end
    fail!(path, "@trashed on #{trashed.first} cannot filter models searched together, each with its own soft deletes") if trashed
    defaulted_constraints.each do |constraint|
      fail!(path, "#{name} cannot apply #{constraint}, whose default value would apply to every search; remove the default")
    end
  end

  def no_engine!(path, models)
    engines = models.map { |model| "#{model.name} (#{engine_name(model)})" }
    fail!(path, "no engine searches #{abstract_name}'s models together: #{engines.join(', ')}. One engine searches them " \
                'all: Searchkick, or pg_search through its multisearch documents')
  end

  def engine_name(model) = Lighthouse::Search.adapter_for(model)&.class&.name&.demodulize || 'not searchable'

  def together_can_query!(path, can_query)
    return if Lighthouse::Support::DirectiveArgs.literal(can_query, 'scopes').blank?

    fail!(path, 'the `scopes:` of @canQuery cannot narrow models searched together; remove them')
  end

  def abstract_name = returned.graphql_name
end
