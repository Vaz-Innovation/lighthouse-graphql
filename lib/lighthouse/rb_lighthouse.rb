# frozen_string_literal: true

# ActiveSupport core extensions the library relies on (underscore, pluralize,
# blank?/present?, deep_symbolize_keys, index_by/pluck/exclude?). In a Rails host these are already
# loaded; requiring them here keeps the gem usable standalone.
require 'active_support'
require 'active_support/core_ext/string/inflections'
require 'active_support/core_ext/object/blank'
require 'active_support/core_ext/hash/keys'
require 'active_support/core_ext/enumerable'
require 'active_support/core_ext/string/exclude'
require 'set'
require 'graphql'

require_relative 'namespaces'

## Load internal dependencies individually so a single missing file
## doesn't prevent the rest from loading. Failures are logged but not
## raised so callers can require specific files if needed.
%w[
  config
  errors
  graphql_ruby_patches
  reference_resolver
  support/naming
  support/directive_args
  support/model_resolver
  support/authorization
  support/arguments
  support/batching
  support/soft_deletes
  support/preload
  support/environment
  where_conditions/operator_map
  contracts/directive
  contracts/field_resolver
  contracts/field_middleware
  contracts/field_manipulator
  contracts/arg_manipulator
  contracts/arg_builder
  contracts/field_builder
  schema_stitcher
  document_ast
  generated_resolvers
  default_resolve_dispatcher
  federation_directives
  field_resolver_stack
  events
  events/lifecycle
  events/execution_trace
  events/schema_build
  resolver_bases
  root_types
  ast_builder
  server_directives
  schema_printer
  schema_report
  schema_generator
  schema_cache
  persisted_queries
  persisted_queries/batch
  persisted_queries/manifest
  operations
  controller
  schema_factory
  schema_implementation
  resolver_dispatch
  caching
  cache_control
  feature_directive
  complexity
  complexity_analyzer
  broadcasting
  subscription
  type
  type_resolution
  resolve_info
  global_id
  enum_directive
  upload
  upload_store
  multipart_request
  node_registry
  scalar_coercion
  pagination
  relation_batch
  relation_counts
  nested_mutations
  directives/pagination_manipulator
  directives/generated_types
  order_by/types
  where_conditions/json_column
  where_conditions/columns
  where_conditions/types
  where_conditions/handler
  directives/soft_deletes_directive
  directives/node_directive
  directives/model_directive
  directives/visibility_directive
  directive_resolvers/aggregate_resolver
  directive_resolvers/field_resolver
  directive_resolvers/all_resolver
  directive_resolvers/find_resolver
  directive_resolvers/paginate_resolver
  directive_resolvers/auth_resolver
  directive_resolvers/first_resolver
  directive_resolvers/count_resolver
  directive_resolvers/rename_resolver
  directive_resolvers/method_resolver
  directive_resolvers/base
  directive_resolvers/resolution
  directive_resolvers/guard_resolver
  directive_resolvers/association_resolvers
  directive_resolvers/can_resolvers
  directive_resolvers/convention_resolver
  directive_resolvers/type_method_resolver
  directive_resolvers/model_mutation_resolver
  directive_resolvers/soft_delete_resolvers
  directive_resolvers/cache_resolvers
  directive_resolvers/validator_resolver
  directive_resolvers/subscription_resolver
  directive_resolvers/broadcast_resolver
  directive_resolvers/event_resolver
  directive_resolvers/convert_empty_strings_resolver
  directive_resolvers/with_resolver
  directive_resolvers/attachment_resolver
  directive_resolvers/with_count_resolver
  directive_resolvers/lazy_load_resolver
  directive_resolvers/limit_resolver
  directive_resolvers/namespaced_resolver
  directive_resolvers/throttle_resolver
  directive_resolvers/async_resolver
  directive_resolvers/global_id_resolver
  directive_resolvers/argument_binding
  directive_resolvers/global_id_types
  directive_resolvers/argument_transforms_resolver
  directives/arguments/base
  directives/arguments/filters
  directives/arguments/more_filters
  directives/arguments/order_by
  directives/arguments/where_conditions_base
  directives/arguments/where_conditions
  directives/arguments/where_has_conditions
  directives/arguments/soft_deletes
  directives/definitions
  directives/registry
  dataloader_sources/association_loader
  dataloader_sources/model_loader
  dataloader_sources/relation_page_loader
  dataloader_sources/relation_count_loader
  dataloader_sources/relation_counts_loader
  dataloader_sources/preload_loader
  ide_helper
].each do |rel|
  require_relative rel
rescue LoadError => e
  warn("Lighthouse: could not require #{rel}: #{e.message}")
end

# The activejob gem is optional: the job that queues @broadcast loads on first use.
Lighthouse::GraphQL.autoload(:BroadcastJob, File.expand_path('broadcast_job.rb', __dir__))
Lighthouse::GraphQL.autoload(:AsyncMutationJob, File.expand_path('async_mutation_job.rb', __dir__))

require_relative 'railtie' if defined?(Rails::Railtie)

module Lighthouse::GraphQL::RbLightHouse
  class << self
    def get_schema(schema_path: nil, options: {})
      base_types = options.delete(:base_types) || {}
      schema_class = options.delete(:base_schema)

      Lighthouse::GraphQL::SchemaFactory.build_base_schema(
        schema_path: schema_path,
        base_types: base_types,
        schema_options: options.merge(schema_class: schema_class)
      )
    end

    def configure(&block)
      Lighthouse::GraphQL::Config.configure(&block) if defined?(Lighthouse::GraphQL::Config)
    end
  end
end
