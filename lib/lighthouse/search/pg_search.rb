# frozen_string_literal: true

# pg_search (PostgreSQL full-text search, in the database). A pg_search scope
# returns an ActiveRecord::Relation, so the search composes with everything
# else Lighthouse applies to the query: scopes, @builder, @whereAuth, argument
# filters, @orderBy and nested fields. pg_search orders the rows by rank first;
# the relation's own orders, the client's `orderBy` and the primary key follow.
#
# `within:` names the `pg_search_scope` to search with, `search` by default:
#
#   pg_search_scope :search, against: %i[title body]
#
# The model's `search_results` scope, if it has one, narrows the search too
# (Lighthouse::Search).
#
# The gem is not a dependency of Lighthouse: the adapter is used when the
# model includes PgSearch::Model.
class Lighthouse::Search::PgSearch
  DEFAULT_SCOPE = :search

  def searchable?(model, index = nil)
    !!(defined?(::PgSearch::Model) && model.include?(::PgSearch::Model) && pg_search_scope?(model, scope_name(index)))
  end

  def relational? = true

  # Does `index` name one of the model's pg_search scopes? (Search::Auto)
  def named?(model, index) = !index.nil? && searchable?(model, index)

  # The relation narrowed to the records that match, ordered by rank first: a
  # search is in order of relevance, so the orders the relation had (the model's
  # default scope, the field's `scopes:`, the search_results scope) break the ties
  # of rank, before the client's `orderBy` and the field's @orderBy, applied after.
  # pg_search's own tie-break, the primary key (unless the scope names
  # `order_within_rank:`), is dropped so that they decide; the key still ends the
  # order, after them (BaseDirectiveResolver#apply_search).
  def scope(relation, query)
    relation = Lighthouse::Search.results(relation)
    searched = relation.public_send(scope_name(query.index), query.term)
    added = searched.order_values.drop(relation.order_values.size)
    orders = [*without_key_tie_break(added, relation.klass), *relation.order_values]
    orders.empty? ? searched : searched.reorder(*orders)
  end

  private

  def scope_name(index) = (index || DEFAULT_SCOPE).to_sym

  # Is the model's class method `name` a pg_search scope? pg_search keeps no list
  # of them: `pg_search_scope` defines each from pg_search/model.rb (2.3 and 2.4
  # alike), which the method's source tells, so another gem's method of the name
  # (Searchkick's `search`, on a model that uses both) is not taken for one.
  def pg_search_scope?(model, name)
    return false unless model.respond_to?(name)

    !!model.method(name).source_location&.first&.end_with?(File.join('pg_search', 'model.rb'))
  end

  # pg_search's orders without its primary-key tie-break, which is a node of its
  # own after the rank's in pg_search 2.4, and the end of one SQL literal in 2.3
  # ("pg_search_1.rank DESC, \"posts\".\"id\" ASC"); the orders themselves when it
  # has none (`order_within_rank:`).
  def without_key_tie_break(orders, model)
    last = orders.last
    return orders[0...-1] if key_node?(last, model)

    tie_break = ", #{model.quoted_table_name}.#{model.connection.quote_column_name(model.primary_key)} ASC"
    return orders unless last.is_a?(String) && last.end_with?(tie_break)

    [*orders[0...-1], ::Arel.sql(last.delete_suffix(tie_break))]
  end

  def key_node?(order, model)
    order.is_a?(::Arel::Nodes::Ascending) && order.expr == model.arel_table[model.primary_key]
  end
end
