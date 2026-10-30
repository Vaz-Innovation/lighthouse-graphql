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
# Models searched together (Search::Together) are searched through pg_search's
# multisearch, the documents each `multisearchable` model keeps in one table
# (PgSearch::Document, `pg_search_documents`), ranked together. A document counts only
# when its record is one its model's relation selects (the model's default scope, its
# search_results scope, the field's @eq on a column of its): the documents are narrowed
# in the database, so pages and totals hold only what loads. Each page loads its records
# through the same relations, a query per model.
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

  # Models searched together: those that include PgSearch::Model, which must keep multisearch
  # documents (`multisearchable`), whether or not they have a pg_search scope of their own.
  def searchable_together?(model) = !!(defined?(::PgSearch::Model) && model.include?(::PgSearch::Model))

  def together_error(model)
    return nil if model.respond_to?(:pg_search_multisearchable_options)

    "#{model.name} keeps no pg_search multisearch documents, which models searched together are searched through: " \
      'call `multisearchable against: [...]` in it'
  end

  # Models searched together: [one entry per document at `offset`, `limit` of them, in rank
  # order: its record, or nil for one that did not load; how many documents match].
  def page(query, offset:, limit:)
    options!(query)
    documents = documents(query)
    found = limit.zero? ? [] : documents.offset(offset).limit(limit).to_a
    [records(query, found), documents.unscope(:order, :select).count]
  end

  # pg_search has no result window.
  def result_window(_query) = nil

  private

  # The documents that match, in rank order, each one's record selected by its model's relation.
  def documents(query)
    kept = query.models.map do |model|
      ::PgSearch::Document.where(searchable_type: model.polymorphic_name, searchable_id: relation(query.for(model)).select(model.primary_key))
    end
    ::PgSearch.multisearch(query.term).where(id: kept.reduce(:or).select(:id))
  end

  # The model's records a search of it may answer: its relation and search_results scope, with the
  # field's @eq conditions; none where a condition names a column the model does not have.
  def relation(query)
    model = query.model
    query.wheres.reduce(Lighthouse::Search.results(model.all)) do |relation, (column, value)|
      model.column_names.include?(column) ? relation.where(column => value) : relation.none
    end
  end

  # The records of `documents`, in their order, nil for one its model's relation no longer selects.
  # The models that share a document type (an STI class and its subclasses) each load theirs.
  def records(query, documents)
    loaded = documents.group_by(&:searchable_type).to_h do |type, typed|
      ids = typed.map(&:searchable_id)
      found = query.models.select { |model| model.polymorphic_name == type }.flat_map do |model|
        relation(query.for(model)).where(model.primary_key => ids).to_a
      end
      [type, found.index_by { |record| record.id.to_s }]
    end
    documents.map { |document| loaded.dig(document.searchable_type, document.searchable_id.to_s) }
  end

  # An @builder's Searchkick options, which multisearch cannot take: one that narrows what loads
  # (`scope_results:`) would be dropped.
  def options!(query)
    return if query.options.empty?

    raise Lighthouse::DefinitionError,
          "@search: pg_search's multisearch takes no option of Searchkick's, which an @builder set: #{query.options.keys.join(', ')}"
  end

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
