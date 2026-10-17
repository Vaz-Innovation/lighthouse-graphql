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

  def self.definition
    'directive @paginate(type: PaginateType = PAGINATOR, model: String, scopes: [String!], ' \
      'defaultCount: Int, maxCount: Int) on FIELD_DEFINITION'
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
    return decorate_relation(model_class.all, args, ctx) unless nested?(obj, name)

    dataloader = Lighthouse::Support::Batching.dataloader(ctx)
    batch = dataloader && Lighthouse::GraphQL::RelationBatch.for(obj, name, args, self, ctx)
    return Lighthouse::GraphQL::Pagination::BatchedList.new(batch, obj, dataloader) if batch

    decorate_relation(obj.association(name.to_sym).scope, args, ctx)
  end

  def nested?(obj, name)
    !directive_arg('model') && obj.respond_to?(:association) && obj.class.reflect_on_association(name.to_sym)
  end

  public

  # `scopes:`, @builder and the argument filters, on one relation or a RelationBatch.
  def decorate_relation(relation, args, ctx)
    relation = Lighthouse::GraphQL::DirectiveResolvers::BuilderApplier.apply(apply_scopes(relation), @field_def.ast_node, args, ctx, self)
    apply_where_filters(relation, args)
  end

  protected

  def limits
    limits = { default_count: directive_arg('defaultCount') }
    given = @directive_node.arguments.any? { |a| a.name == 'maxCount' }
    limits[:max_count] = directive_arg('maxCount') || :unlimited if given
    limits
  end
end
