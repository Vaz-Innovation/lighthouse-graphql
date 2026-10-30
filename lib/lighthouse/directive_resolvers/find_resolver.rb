# frozen_string_literal: true

require_relative 'base'

# @find — the single record the field's argument filters select:
#
#   user(id: ID! @eq): User @find
#   userByEmail(email: String! @eq): User @find
#
# A lookup by `id` alone is batched through the Dataloader, and an `id`
# argument without a filter directive selects by primary key. More than one
# match is an error, as in PHP Lighthouse; none returns null.
class Lighthouse::GraphQL::DirectiveResolvers::FindDirectiveResolver < Lighthouse::GraphQL::DirectiveResolvers::BaseDirectiveResolver
  def self.directive_name = 'find'
  def self.applies_search? = true

  # It finds in the model's whole table, so it takes the records an engine answers
  # with (Searchkick); not with an `id` argument that has no filter directive, which
  # selects by primary key in the database only.
  def self.takes_search_results?(_type, field_def, _directive, _root_kind) = !primary_key_argument?(field_def)

  # Does the field have an `id` argument without a filter directive (@eq, @where, ...),
  # which selects by primary key?
  def self.primary_key_argument?(field_def)
    argument = (field_def.ast_node&.arguments || []).find { |a| a.name == 'id' }
    registry = Lighthouse::DirectiveRegistry.default
    !argument.nil? && argument.directives.none? { |d| registry.arg_builder_class(d.name) }
  end

  def self.definition
    <<~GRAPHQL.chomp
      """
      Find a single record by the field's argument filters (@eq, @where, ...), or null.
      More than one match is an error. A lookup by `id` alone is batched.
      """
      directive @find(
      #{MODEL_ARGUMENT}
      #{SCOPES_ARGUMENT}
      ) on FIELD_DEFINITION
    GRAPHQL
  end

  def define_resolver(target_type_class)
    # Only a field with no scopes and no query directive of its own (@builder, @whereAuth) can batch a lookup by `id`.
    @batchable = !directive_arg('scopes') && Lighthouse::GraphQL::DirectiveResolvers::BuilderApplier.query_directives(@field_def.ast_node).empty?
    me = self
    install(target_type_class, lambda do |_obj, args, ctx|
      me.send(:find, Lighthouse::Support::Arguments.shallow(args), ctx)
    end)
  end

  protected

  def find(args, ctx)
    model = model_class
    dataloader = Lighthouse::Support::Batching.dataloader(ctx)
    return dataloader.with(Lighthouse::GraphQL::DataloaderSources::ModelLoader, model).load(args[:id]) if dataloader && batchable?(args)

    found = find_relation(model, args, ctx)
    return found.only_record if found.is_a?(Lighthouse::Search::Result)

    records = found.limit(2).to_a
    raise ::GraphQL::ExecutionError, 'The query returned more than one result.' if records.size > 1

    records.first
  end

  # Only a lookup by `id` alone, with no scopes and no query directive of the
  # field's own (@builder, @whereAuth) to apply, can be batched.
  def batchable?(args) = @batchable && args.keys == [:id]

  # The model's relation, filtered; or the search an engine answers (Search::Result).
  # One narrowed by primary key is not the model's own, which an engine would search
  # whole: Search::Enhancer refuses it (`search: :given`), as Search::FieldCheck does
  # when the schema is built.
  def find_relation(model, args, ctx)
    relation = apply_scopes(model.all)
    by_key = args.key?(:id) && self.class.primary_key_argument?(@field_def)
    relation = relation.where(model.primary_key => args[:id]) if by_key
    apply_where_filters(relation, args, ctx, search: by_key ? :given : :model)
  end
end
