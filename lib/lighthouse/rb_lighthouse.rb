# frozen_string_literal: true

# ActiveSupport core extensions the library relies on (underscore, pluralize,
# blank?/present?, deep_symbolize_keys). In a Rails host these are already
# loaded; requiring them here keeps the gem usable standalone.
require 'active_support'
require 'active_support/core_ext/string/inflections'
require 'active_support/core_ext/object/blank'
require 'active_support/core_ext/hash/keys'

## Load internal dependencies individually so a single missing file
## doesn't prevent the rest from loading. Failures are logged but not
## raised so callers can require specific files if needed.
%w[
  config
  reference_resolver
  support/naming
  support/directive_args
  support/model_resolver
  support/authorization
  where_conditions/operator_map
  contracts/directive
  contracts/field_resolver
  contracts/field_middleware
  contracts/field_manipulator
  contracts/arg_manipulator
  contracts/arg_builder
  sdl_loader
  schema_generator
  schema_factory
  schema_implementation
  directives/relation_directive
  directives/where_conditions_directive
  directive_resolvers/has_many_resolver
  directive_resolvers/aggregate_resolver
  directive_resolvers/field_resolver
  directive_resolvers/where_conditions_applier
  directive_resolvers/belongs_to_resolver
  directive_resolvers/all_resolver
  directive_resolvers/find_resolver
  directive_resolvers/paginate_resolver
  directive_resolvers/auth_resolver
  directive_resolvers/belongs_to_many_resolver
  directive_resolvers/has_one_resolver
  directive_resolvers/first_resolver
  directive_resolvers/count_resolver
  directive_resolvers/rename_resolver
  directive_resolvers/method_resolver
  directive_resolvers/base
  directive_resolvers/resolution
  directive_resolvers/guard_resolver
  directive_resolvers/can_resolver
  directives/arguments/base
  directives/arguments/filters
  directives/arguments/order_by
  directives/registry
  dataloader_sources/association_loader
  dataloader_sources/model_loader
].each do |rel|
  begin
    require_relative rel
  rescue LoadError => e
    warn("Lighthouse: could not require #{rel}: #{e.message}")
  end
end

module Lighthouse
  module GraphQL
    module RbLightHouse
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
  end
end
