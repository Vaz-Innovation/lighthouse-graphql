# frozen_string_literal: true

# The pages of one paginated relation for many parents at once — what PHP
# Lighthouse's PaginatedModelsLoader does with a UNION ALL per parent and
# `loadCount`. Here a window function numbers each parent's rows, so the pages
# of every parent come from one query, and one GROUP BY counts them all:
#
#   SELECT * FROM (
#     SELECT comments.*, ROW_NUMBER() OVER (PARTITION BY comments.author_id ORDER BY ...) AS lighthouse_row,
#            comments.author_id AS lighthouse_owner
#     FROM comments WHERE comments.author_id IN (1, 2, 3) AND <the field's scopes and filters>
#   ) comments WHERE lighthouse_row > 0 AND lighthouse_row <= 10
#
#   SELECT COUNT(*), comments.author_id FROM comments WHERE ... GROUP BY comments.author_id
#
# A parent's association scope links it through one column on the table
# nearest to it (comments.author_id; taggings.post_id for a :through), which
# ActiveRecord's reflection names. The batch swaps that link for an IN over
# every parent and partitions by the same column. The field's scopes and
# filters (`decorator.decorate_relation`) apply on top, as for one parent.
#
# A batch is equal to another for the same field, parent class and arguments,
# so the Dataloader collects every parent of a level into one.
class Lighthouse::GraphQL::RelationBatch
  ROW = 'lighthouse_row'
  OWNER = 'lighthouse_owner'

  attr_reader :association_name

  # The batch `owner`'s page belongs to, or nil when this relation cannot be
  # batched (the database has no window functions, a composite key, a scope
  # that reads the owner, DISTINCT, ...): each parent then loads its own page.
  def self.for(owner, association_name, args, decorator, context)
    return nil unless owner.respond_to?(:association) && owner.class.respond_to?(:reflect_on_association)
    return nil unless owner.class.reflect_on_association(association_name.to_sym)&.collection?

    batch = new(owner.class, association_name.to_s, args, decorator, context)
    batch if batch.batchable?(owner)
  end

  def self.window_functions?(connection)
    version = connection.database_version
    case connection.adapter_name
    when /postg/i then true
    when /sqlite/i then version >= '3.25'
    when /mysql|trilogy/i then version >= (connection.respond_to?(:mariadb?) && connection.mariadb? ? '10.2' : '8.0')
    else false
    end
  rescue StandardError
    false
  end

  def initialize(owner_class, association_name, args, decorator, context)
    @owner_class = owner_class
    @association_name = association_name
    @args = args
    @decorator = decorator
    @context = context
  end

  def batchable?(owner)
    linked_by_one_column?(owner) && self.class.window_functions?(owner.class.connection) &&
      owner_independent?(owner) && rankable?(relation([owner]))
  end

  # { owner key => its records in rows offset+1..offset+limit }
  def pages(owners, offset, limit)
    relation = relation(owners)
    ranked = relation.unscope(:order).select(*selection(relation), "#{row_number(relation)} AS #{ROW}", "#{partition} AS #{OWNER}")
    rows = relation.klass.unscoped.from(ranked, relation.klass.table_name)
                   .where("#{ROW} > ? AND #{ROW} <= ?", offset, offset + limit)
                   .order(Arel.sql("#{OWNER}, #{ROW}"))
    preloads = relation.preload_values + relation.includes_values
    rows = rows.preload(*preloads) if preloads.any?
    rows.to_a.group_by { |record| record[OWNER].to_s }
  end

  # { owner key => number of related records }
  def counts(owners)
    relation(owners).unscope(:order, :select).group(Arel.sql(partition)).count.transform_keys(&:to_s)
  end

  def owner_key(owner)
    owner[@owner_column].to_s
  end

  def eql?(other)
    other.is_a?(self.class) && identity == other.identity
  end
  alias == eql?

  def hash
    identity.hash
  end

  protected

  def identity
    @identity ||= [@owner_class, @association_name, @decorator, Lighthouse::Support::Arguments.plain(@args)]
  end

  private

  # The column on the table nearest the owner that holds the owner's key —
  # where ActiveRecord's AssociationScope puts the owner's condition.
  def linked_by_one_column?(owner)
    link = owner.association(@association_name.to_sym).reflection.chain.last
    return false unless link.respond_to?(:join_primary_key)

    @link_table = link.klass.table_name
    @link_column = link.join_primary_key
    @owner_column = link.join_foreign_key
    [@link_column, @owner_column].none?(Array)
  end

  # The owner's condition can be swapped for an IN, and no scope reads the owner.
  def owner_independent?(owner)
    association = owner.association(@association_name.to_sym)
    association.reflection.chain.none? { |reflection| reflection.scope&.arity&.positive? } &&
      unlinked(association.scope).where_clause != association.scope.where_clause
  end

  # Rows can be numbered in a stable order, and DISTINCT does not fold them.
  def rankable?(relation)
    !relation.distinct_value && (relation.arel.orders.any? || relation.klass.primary_key.is_a?(String))
  end

  def relation(owners)
    scope = unlinked(owners.first.association(@association_name.to_sym).scope)
    keys = owners.pluck(@owner_column).uniq
    @decorator.decorate_relation(scope.where(@link_table => { @link_column => keys }), @args, @context)
  end

  def unlinked(scope)
    scope.unscope(where: { @link_table => @link_column })
  end

  def partition
    connection = @owner_class.connection
    "#{connection.quote_table_name(@link_table)}.#{connection.quote_column_name(@link_column)}"
  end

  # Numbers each parent's rows in the order the field asks for, else by primary key.
  def row_number(relation)
    orders = relation.arel.orders.map { |node| node.respond_to?(:to_sql) ? node.to_sql : node.to_s }
    if orders.empty?
      connection = relation.klass.connection
      orders = ["#{connection.quote_table_name(relation.klass.table_name)}.#{connection.quote_column_name(relation.klass.primary_key)}"]
    end
    "ROW_NUMBER() OVER (PARTITION BY #{partition} ORDER BY #{orders.join(', ')})"
  end

  def selection(relation)
    relation.select_values.presence || [relation.klass.arel_table[Arel.star]]
  end
end
