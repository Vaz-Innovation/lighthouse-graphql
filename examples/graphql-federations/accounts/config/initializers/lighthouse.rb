# Lighthouse's defaults suit this subgraph; see ../../../docs/configuration.md.
Lighthouse.configure do |config|
  # The router sends Lighthouse's persisted queries (its `apq.subgraph` setting):
  # the hash first, then the query when the subgraph does not know it yet.
  config.persisted_queries = true
end
