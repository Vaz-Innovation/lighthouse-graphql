# frozen_string_literal: true

# The total of a paginated relation for every parent the Dataloader collected,
# in one GROUP BY query. Only asked for when the client selects a total.
class Lighthouse::GraphQL::DataloaderSources::RelationCountLoader < GraphQL::Dataloader::Source
  def initialize(batch)
    super()
    @batch = batch
  end

  # keys: the parent records
  def fetch(owners)
    counts = @batch.counts(owners)
    owners.map { |owner| counts.fetch(@batch.owner_key(owner), 0) }
  end
end
