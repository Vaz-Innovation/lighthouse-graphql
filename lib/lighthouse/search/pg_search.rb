# frozen_string_literal: true

# pg_search (PostgreSQL full-text search, in the database). A pg_search scope
# returns an ActiveRecord::Relation, so the search composes with everything
# else Lighthouse applies to the query: scopes, @builder, @whereAuth, argument
# filters, @orderBy and nested fields. pg_search orders the rows by rank first;
# the client's `orderBy` and the primary key follow.
#
# `within:` names the `pg_search_scope` to search with, `search` by default:
#
#   pg_search_scope :search, against: %i[title body]
#
# The gem is not a dependency of Lighthouse: the adapter is used when the
# model includes PgSearch::Model.
class Lighthouse::Search::PgSearch
  DEFAULT_SCOPE = :search

  def searchable?(model, index = nil)
    !!(defined?(::PgSearch::Model) && model.include?(::PgSearch::Model) && model.respond_to?(scope_name(index)))
  end

  def relational? = true

  # The relation narrowed to the records that match and ordered by rank.
  def scope(relation, query)
    relation.public_send(scope_name(query.index), query.term)
  end

  private

  def scope_name(index) = (index || DEFAULT_SCOPE).to_sym
end
