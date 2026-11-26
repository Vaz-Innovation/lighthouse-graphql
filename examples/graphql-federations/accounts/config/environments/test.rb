# The end-to-end suite runs each subgraph as a server (spec/support/stack.rb), in this environment.
Rails.application.configure do
  config.enable_reloading = false
  config.eager_load = true
  config.consider_all_requests_local = true
  config.cache_store = :memory_store
  config.action_dispatch.show_exceptions = :rescuable
  config.active_support.deprecation = :stderr
  config.log_level = :info
end

Rails.application.configure { config.active_storage.service = :test }
