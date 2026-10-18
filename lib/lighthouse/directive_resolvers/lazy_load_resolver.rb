# frozen_string_literal: true

require_relative 'base'

# @lazyLoad(relations: ["replies"]) — eager-load relations of the records a field
# returns, as PHP Lighthouse's @lazyLoad does, so the fields the client selects on
# them do not query once per record. Works on a list, a relation, and a @paginate
# page; across every parent in the response at once, so a @hasMany's records for
# all its parents load their relations together.
#
#   type Post {
#     comments: [Comment!]! @hasMany @lazyLoad(relations: ["replies", "author"])
#   }
class Lighthouse::GraphQL::DirectiveResolvers::LazyLoadDirectiveResolver < Lighthouse::GraphQL::DirectiveResolvers::BaseDirectiveResolver
  def self.directive_name = 'lazyLoad'

  def self.definition
    <<~GRAPHQL.chomp
      """
      Eager-load relations of the records the field returns.
      """
      directive @lazyLoad(
        "The relations to load, nested with dots."
        relations: [String!]!
      ) repeatable on FIELD_DEFINITION
    GRAPHQL
  end

  def define_resolver(target_type_class)
    inner = capture_inner(target_type_class)
    associations = Lighthouse::Support::Preload.associations(directive_arg('relations'))

    install(target_type_class, lambda do |obj, args, ctx|
      Lighthouse::GraphQL::DirectiveResolvers::LazyLoadDirectiveResolver.load(inner.call(obj, args, ctx), associations, ctx)
    end)
  end

  # `result` with `associations` loaded into its records.
  def self.load(result, associations, ctx)
    return result.preload(*associations) if unloaded_relation?(result)

    records = records_of(result).grep(::ActiveRecord::Base)
    ctx.dataloader.with(Lighthouse::GraphQL::DataloaderSources::PreloadLoader, associations, []).load_all(records) if records.any?
    result
  end

  # A query not run yet takes the preload itself. An association's records (what
  # @hasMany returns, loaded for every parent at once) or a loaded relation
  # are records already: they load their relations together, in the Dataloader.
  def self.unloaded_relation?(result)
    result.is_a?(::ActiveRecord::Relation) && !result.is_a?(::ActiveRecord::Associations::CollectionProxy) && !result.loaded?
  end

  def self.records_of(result)
    case result
    when Lighthouse::GraphQL::Pagination::LazyPage then result.items
    when Hash then Array(result['data'] || result[:data])
    else Array(result)
    end
  end
end
