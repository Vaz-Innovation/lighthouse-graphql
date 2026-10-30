# frozen_string_literal: true

# The default adapter: asks each engine, in order (Searchkick, then pg_search),
# whether the model uses it. A `within:` that names something of one engine's on
# the model (a pg_search scope; `named?(model, index)`) picks that engine, even
# for a model that uses both: Searchkick takes any `within:` as an index name.
# `Config.search` replaces it with one adapter.
class Lighthouse::Search::Auto
  def initialize(adapters = nil)
    @adapters = adapters || [Lighthouse::Search::Searchkick.new, Lighthouse::Search::PgSearch.new]
  end

  # The adapter that searches `model` (within the scope or index `index` names), or nil.
  def adapter_for(model, index = nil)
    searching = @adapters.select { |adapter| adapter.searchable?(model, index) }
    named = index && searching.find { |adapter| adapter.respond_to?(:named?) && adapter.named?(model, index) }
    named || searching.first
  end

  def searchable?(model, index = nil) = !adapter_for(model, index).nil?

  # The first adapter that searches every one of `models` together, or nil.
  def adapter_together(models)
    @adapters.find { |adapter| adapter.respond_to?(:together_error) && models.all? { |model| adapter.searchable_together?(model) } }
  end
end
