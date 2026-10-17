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
  where_conditions/operator_map
  contracts/directive
  contracts/field_resolver
  contracts/field_middleware
  contracts/field_manipulator
  contracts/arg_manipulator
  contracts/arg_builder
  sdl_loader
  generated_resolvers
  federation_directives
  field_resolver_stack
  schema_generator
  schema_cache
  persisted_queries
  schema_factory
  schema_implementation
  resolver_dispatch
  caching
  cache_control
  pagination
  relation_batch
  nested_mutations
  directives/pagination_manipulator
  directives/where_conditions_directive
  directive_resolvers/aggregate_resolver
  directive_resolvers/field_resolver
  directive_resolvers/where_conditions_applier
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
  directive_resolvers/model_mutation_resolver
  directive_resolvers/cache_resolvers
  directive_resolvers/validator_resolver
  directives/arguments/base
  directives/arguments/filters
  directives/arguments/order_by
  directives/registry
  dataloader_sources/association_loader
  dataloader_sources/model_loader
  dataloader_sources/relation_page_loader
  dataloader_sources/relation_count_loader
  ide_helper
].each do |rel|
  require_relative rel
rescue LoadError => e
  warn("Lighthouse: could not require #{rel}: #{e.message}")
end

require_relative 'railtie' if defined?(Rails::Railtie)

module Lighthouse::GraphQL::RbLightHouse
  class << self
    def get_schema(sdl_folder: nil, options: {})
      base_types = options.delete(:base_types) || {}
      schema_class = options.delete(:base_schema)

      Lighthouse::GraphQL::SchemaFactory.build_base_schema(
        sdl_folder: sdl_folder,
        base_types: base_types,
        schema_options: options.merge(schema_class: schema_class)
      )
    end

    def configure(&block)
      Lighthouse::GraphQL::Config.configure(&block) if defined?(Lighthouse::GraphQL::Config)
    end
  end
end
