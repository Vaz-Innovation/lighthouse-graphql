# frozen_string_literal: true

# How many related records each parent has, for @withCount: every parent the
# Dataloader collected in one GROUP BY query when the relation can be batched
# (RelationBatch), else one COUNT per parent. Each count is kept on its parent
# as `<relation>_count` (RelationCounts).
class Lighthouse::GraphQL::DataloaderSources::RelationCountsLoader < GraphQL::Dataloader::Source
  # Applies the directive's scopes, then the scope_items of the related model's
  # type (TypeAuthorization), to the related records, as RelationBatch applies a
  # field's filters. A value, so equal scopes batch together.
  Scopes = Struct.new(:names, :context) do
    def decorate_relation(relation, _args, _context)
      scoped = Array(names).reduce(relation) { |acc, scope| acc.public_send(scope) }
      Lighthouse::GraphQL::TypeAuthorization.scope_model(scoped, context)
    end
  end

  def initialize(relation, scopes, context = nil)
    super()
    @relation = relation.to_s
    @scopes = Scopes.new(Array(scopes), context)
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
