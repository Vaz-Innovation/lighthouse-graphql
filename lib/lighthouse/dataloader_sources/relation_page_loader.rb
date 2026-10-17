# frozen_string_literal: true

# One page of a paginated relation for every parent the Dataloader collected,
# in one query (see Lighthouse::GraphQL::RelationBatch).
class Lighthouse::GraphQL::DataloaderSources::RelationPageLoader < GraphQL::Dataloader::Source
  def initialize(batch, offset, limit)
    super()
    @batch = batch
    @offset = offset
    @limit = limit
  end

  # keys: the parent records
  def fetch(owners)
    pages = @batch.pages(owners, @offset, @limit)
    owners.map { |owner| pages.fetch(@batch.owner_key(owner), []) }
  end
end
