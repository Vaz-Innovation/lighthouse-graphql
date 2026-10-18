# frozen_string_literal: true

require_relative 'base'

# @withCount(relation: "posts", scopes: [...]) — count a relation of the parent
# before the field resolves, as PHP Lighthouse's @withCount does: the count is not
# the field's value, it is kept on the parent as `<relation>_count`
# (`user.posts_count`) for whatever resolves the field to read. Every parent in
# the response is counted in one query.
#
#   type User {
#     activity: String! @withCount(relation: "posts") @method(name: "activity_label")
#     postsCount: Int! @withCount(relation: "posts")   # the default reader reads posts_count
#   }
class Lighthouse::GraphQL::DirectiveResolvers::WithCountDirectiveResolver < Lighthouse::GraphQL::DirectiveResolvers::BaseDirectiveResolver
  def self.directive_name = 'withCount'

  def self.definition
    <<~GRAPHQL.chomp
      """
      Count a relation of the parent before the field resolves, for every parent at once,
      and keep the count on it as `<relation>_count`.
      """
      directive @withCount(
        "The relation to count."
        relation: String!
        "Model scopes that narrow the counted records."
        scopes: [String!]
      ) repeatable on FIELD_DEFINITION
    GRAPHQL
  end

  def define_resolver(target_type_class)
    inner = capture_inner(target_type_class)
    relation = directive_arg('relation')
    scopes = Array(directive_arg('scopes'))

    install(target_type_class, lambda do |obj, args, ctx|
      ctx.dataloader.with(Lighthouse::GraphQL::DataloaderSources::RelationCountsLoader, relation, scopes).load(obj) if obj.is_a?(::ActiveRecord::Base)
      inner.call(obj, args, ctx)
    end)
  end
end
