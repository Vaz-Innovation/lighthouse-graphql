# frozen_string_literal: true

require_relative 'base'

# @search -- on a String argument: when the client sends a string (`""` too;
# null or nothing falls back to the database query), the field's query runs
# through a full-text engine (see Lighthouse::Search), as PHP Lighthouse's
# @search does through Laravel Scout.
#
#   posts(search: String @search, authorId: ID @eq): [Post!]! @paginate
#
# `within:` names the index (Searchkick) or the pg_search scope. The directive
# constrains nothing itself: the field's resolver acts on it
# (BaseDirectiveResolver#apply_search) before the argument builders.
class Lighthouse::GraphQL::Directives::Arguments::Search < Lighthouse::GraphQL::Directives::Arguments::Base
  def self.directive_name = 'search'

  def self.definition
    <<~GRAPHQL.chomp
      """
      Perform a full-text search by the given input value.
      """
      directive @search(
      #{argument_sdl('within: String', 'Specify a custom index to use for search.')}
      ) on ARGUMENT_DEFINITION | INPUT_FIELD_DEFINITION
    GRAPHQL
  end

  # The search runs for a string: null, or nothing, leaves the query whole.
  def self.filters?(value) = value.is_a?(String)
  def self.searches? = true

  def handle_builder(relation, _value) = relation
end
