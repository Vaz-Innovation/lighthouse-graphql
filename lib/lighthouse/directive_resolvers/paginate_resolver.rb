# frozen_string_literal: true

require_relative 'base'
require_relative 'builder_applier'

# @paginate — paginate a model query, as PHP Lighthouse does. On a nested
# field it pages the parent's association of the same name.
#
#   users(name: String @like): [User!]! @paginate(defaultCount: 25)
#
# `type:` picks PAGINATOR (default), SIMPLE or CONNECTION (see
# Directives::PaginationManipulator for the generated schema). The query is
# the model's (`model:`, else the return type), narrowed by `scopes:`,
# @builder and the field's argument filters (@eq, @where, @orderBy,
# @whereConditions, ...). `maxCount` caps `first` (null: unlimited),
# overriding Config.pagination_max_count.
class Lighthouse::GraphQL::DirectiveResolvers::PaginateDirectiveResolver < Lighthouse::GraphQL::DirectiveResolvers::BaseDirectiveResolver
  def self.directive_name = 'paginate'

  def self.applies_search? = true

  # The model's whole table takes the records an engine answers with: on a root
  # field, with `model:`, or where the parent type's model has no association of
  # its name. What a parent whose type is no model pages is only known from a
  # query's records (nested?), so it is not taken; nor, at run time, a parent
  # record that has the association its type's model lacks (Search::Enhancer).
  def self.takes_search_results?(type, field_def, directive, root_kind)
    return true if root_kind || Lighthouse::Support::DirectiveArgs.literal(directive, 'model')

    parent = Lighthouse::Support::ModelResolver.model_class(Lighthouse::GraphQL::Directives::ModelDirective.model_for(type))
    !parent.nil? && !pages_association?(parent, Lighthouse::Support::Naming.attribute(field_def.name), directive)
  end

  # Does the field page `parent`'s association of its name, rather than the
  # model's whole table? Not with `model:`, as PHP Lighthouse's.
  def self.pages_association?(parent, name, directive)
    return false if Lighthouse::Support::DirectiveArgs.literal(directive, 'model')

    !!(parent.respond_to?(:reflect_on_association) && parent.reflect_on_association(name.to_sym))
  end

  def self.definition
    <<~GRAPHQL.chomp
      """
      Query multiple model entries as a paginated list.
      The query is the model's, narrowed by `scopes`, @builder and the field's argument filters
      (@eq, @where, @orderBy, ...). On a nested field, it pages the parent's association of the same name.
      """
      directive @paginate(
        "Which pagination style to use."
        type: PaginateType = PAGINATOR
      #{MODEL_ARGUMENT}
      #{SCOPES_ARGUMENT}
        "The page size when the client omits `first`. Defaults to Config.pagination_default_count."
        defaultCount: Int
        "The most records the client may ask for with `first`; null for no limit. Defaults to Config.pagination_max_count."
        maxCount: Int
      ) on FIELD_DEFINITION
    GRAPHQL
  end

  def self.type_definitions
    {
      'PaginateType' => <<~GRAPHQL.chomp
        "The type of pagination a field uses."
        enum PaginateType {
          "Offset-based pagination with page numbers and a total, like Laravel's LengthAwarePaginator."
          PAGINATOR
          "Offset-based pagination without a total count, which saves a query."
          SIMPLE
          "Cursor-based pagination, compatible with the Relay specification."
          CONNECTION
        }
      GRAPHQL
    }
  end

  def define_resolver(target_type_class)
    me = self
    install(target_type_class, lambda do |obj, args, ctx|
      me.send(:resolve_page, obj, Lighthouse::Support::Arguments.shallow(args), ctx)
    end)
  end

  protected

  def resolve_page(obj, args, ctx)
    Lighthouse::GraphQL::Pagination.paginate(page_list(obj, args, ctx), (directive_arg('type') || 'PAGINATOR').to_s.upcase, args, limits)
  end

  # On a nested field, the parent's association of that name (as in PHP
  # Lighthouse, `User.posts @paginate` pages the user's posts), batched with
  # the other parents' when the Dataloader can; otherwise, or with `model:`,
  # the model's whole table.
  def page_list(obj, args, ctx)
    name = Lighthouse::Support::Naming.attribute(@field_def.name)
    return decorate_relation(model_class.all, args, ctx, search: :model) unless nested?(obj, name)

    dataloader = Lighthouse::Support::Batching.dataloader(ctx)
    batch = dataloader && Lighthouse::GraphQL::RelationBatch.for(obj, name, args, self, ctx)
    return Lighthouse::GraphQL::Pagination::BatchedList.new(batch, obj, dataloader) if batch

    decorate_relation(obj.association(name.to_sym).scope, args, ctx)
  end

  def nested?(obj, name)
    obj.respond_to?(:association) && self.class.pages_association?(obj.class, name, @directive_node)
  end

  public

  # `scopes:`, the argument filters and @builder, on one relation or a RelationBatch.
  # `search`: what it takes from a search outside the database (apply_where_filters).
  def decorate_relation(relation, args, ctx, search: nil)
    apply_where_filters(apply_scopes(relation), args, ctx, search: search)
  end

  protected

  def limits
    limits = { default_count: directive_arg('defaultCount') }
    given = @directive_node.arguments.any? { |a| a.name == 'maxCount' }
    limits[:max_count] = directive_arg('maxCount') || :unlimited if given
    limits
  end
end
