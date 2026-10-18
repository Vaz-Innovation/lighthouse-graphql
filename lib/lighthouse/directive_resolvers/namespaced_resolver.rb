# frozen_string_literal: true

require_relative 'base'

# @namespaced — a field that only groups others, as PHP Lighthouse's
# directive: it resolves to `true`, and the fields of its type resolve with
# their own directives.
#
#   type Query { post: PostQueries! @namespaced }
#   type PostQueries {
#     find(id: ID! @eq): Post @find
#     list: [Post!]! @paginate
#   }
#
# `{ post { find(id: 1) { title } } }`. Works on Mutation too.
class Lighthouse::GraphQL::DirectiveResolvers::NamespacedDirectiveResolver < Lighthouse::GraphQL::DirectiveResolvers::BaseDirectiveResolver
  def self.directive_name = 'namespaced'

  def self.definition
    <<~GRAPHQL.chomp
      """
      A no-op field resolver that allows nesting of queries and mutations.
      """
      directive @namespaced on FIELD_DEFINITION
    GRAPHQL
  end

  def define_resolver(target_type_class)
    install(target_type_class, ->(_obj, _args, _ctx) { true })
  end
end
