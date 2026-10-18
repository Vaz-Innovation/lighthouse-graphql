# frozen_string_literal: true

# How many related records each parent has, for @withCount: every parent the
# Dataloader collected in one GROUP BY query when the relation can be batched
# (RelationBatch), else one COUNT per parent. Each count is kept on its parent
# as `<relation>_count` (RelationCounts).
class Lighthouse::GraphQL::DataloaderSources::RelationCountsLoader < GraphQL::Dataloader::Source
  # Applies the directive's scopes to the related records, as RelationBatch
  # applies a field's filters. A value, so equal scopes batch together.
  Scopes = Struct.new(:names) do
    def decorate_relation(relation, _args, _context)
      Array(names).reduce(relation) { |scoped, scope| scoped.public_send(scope) }
    end
  end

  def initialize(relation, scopes)
    super()
    @relation = relation.to_s
    @scopes = Scopes.new(Array(scopes))
  end

  # keys: the parent records, of one class or several
  def fetch(parents)
    counts = {}.compare_by_identity
    parents.group_by(&:class).each_value { |group| counts.merge!(counts_for(group)) }
    parents.map do |parent|
      Lighthouse::GraphQL::RelationCounts.write(parent, @relation, counts[parent])
      counts[parent]
    end
  end

  private

  # { parent => count } for parents of one class.
  def counts_for(parents)
    batch = Lighthouse::GraphQL::RelationBatch.for(parents.first, @relation, {}, @scopes, nil)
    return parents.index_with { |parent| own_count(parent) } unless batch

    counts = batch.counts(parents)
    parents.index_with { |parent| counts.fetch(batch.owner_key(parent), 0) }
  end

  def own_count(parent)
    @scopes.decorate_relation(parent.public_send(@relation), nil, nil).count
  end
end
