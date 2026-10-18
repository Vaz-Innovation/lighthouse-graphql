# frozen_string_literal: true

# Eager-loads associations into every record the Dataloader collected, of
# every parent, in one query per association: @with and @lazyLoad.
class Lighthouse::GraphQL::DataloaderSources::PreloadLoader < GraphQL::Dataloader::Source
  def initialize(associations, scopes)
    super()
    @associations = associations
    @scopes = scopes
  end

  # keys: the records
  def fetch(records)
    Lighthouse::Support::Preload.records(records, @associations, @scopes)
  end
end
