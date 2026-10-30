# frozen_string_literal: true

# The default adapter: asks each engine, in order (Searchkick, then pg_search),
# whether the model uses it. `Config.search` replaces it with one adapter.
class Lighthouse::Search::Auto
  def initialize(adapters = nil)
    @adapters = adapters || [Lighthouse::Search::Searchkick.new, Lighthouse::Search::PgSearch.new]
  end

  # The adapter that searches `model` (within the scope `index` names), or nil.
  def adapter_for(model, index = nil)
    @adapters.find { |adapter| adapter.searchable?(model, index) }
  end

  def searchable?(model, index = nil) = !adapter_for(model, index).nil?
end
