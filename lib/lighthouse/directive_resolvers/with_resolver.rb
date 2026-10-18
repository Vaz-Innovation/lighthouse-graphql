# frozen_string_literal: true

require_relative 'base'

# @with(relation: "tasks", scopes: [...]) — eager-load a relation of the parent
# before the field resolves, as PHP Lighthouse's @with does: for a field computed
# from it (a @method, a type class method, the default reader of a method that
# reads it), so it is loaded once for every parent in the response, not once per
# parent. `relation` defaults to the field's (snake_case) name, and may be nested
# ("tasks.assignee"); `scopes` narrow the loaded records.
#
#   type User {
#     taskSummary: String! @with(relation: "tasks") @method(name: "task_summary")
#   }
class Lighthouse::GraphQL::DirectiveResolvers::WithDirectiveResolver < Lighthouse::GraphQL::DirectiveResolvers::BaseDirectiveResolver
  def self.directive_name = 'with'

  def self.definition
    <<~GRAPHQL.chomp
      """
      Eager-load a relation of the parent before the field resolves, for every parent at once.
      """
      directive @with(
        "The relation to load, nested with dots. Defaults to the field's name."
        relation: String
        "Model scopes that narrow the loaded records."
        scopes: [String!]
      ) repeatable on FIELD_DEFINITION
    GRAPHQL
  end

  def define_resolver(target_type_class)
    inner = capture_inner(target_type_class)
    associations = Lighthouse::Support::Preload.associations(directive_arg('relation') || Lighthouse::Support::Naming.attribute(@field_def.name))
    scopes = Array(directive_arg('scopes'))

    install(target_type_class, lambda do |obj, args, ctx|
      ctx.dataloader.with(Lighthouse::GraphQL::DataloaderSources::PreloadLoader, associations, scopes).load(obj) if obj.is_a?(::ActiveRecord::Base)
      inner.call(obj, args, ctx)
    end)
  end
end
