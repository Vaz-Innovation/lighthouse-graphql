# frozen_string_literal: true

require_relative 'base'

module Lighthouse
  module GraphQL
    module DirectiveResolvers
      class HasManyDirectiveResolver < BaseDirectiveResolver
        def define_resolver(target_type_class)
          field_name = @field_def.name
          assoc_name = extract_relation_name || field_name
          is_connection = @field_def.respond_to?(:connection?) ? @field_def.connection? : false

          resolver_instance = self

          # Keep compatibility with SchemaImplementation-based resolution by
          # defining a singleton method on the owner type (e.g. Inbox.resolve_field_conversations).
          method_name = "resolve_field_#{field_name}"

          target_type_class.define_singleton_method(method_name) do |*args|
            # Support both batch and single resolution modes.
            # Batch mode signature: (objects_array, ctx)
            # Single mode signature: (obj, arguments, ctx)
            if args.length == 2 && args[0].is_a?(Array)
              parents, ctx = args

              if ctx && ctx.respond_to?(:dataloader) && ctx.dataloader
                loader = ctx.dataloader.with(Lighthouse::GraphQL::DataloaderSources::AssociationLoader, parents.first.class, assoc_name)
                parents.map do |p|
                  promise = loader.load(p)
                  if is_connection
                    promise.then { |value| ::GraphQL::Pagination::ArrayConnection.new(value, context: ctx, parent: nil, field: nil, arguments: {}) }
                  else
                    promise
                  end
                end
              else
                parents.map do |p|
                  value = p.respond_to?(assoc_name) ? p.public_send(assoc_name) : nil
                  is_connection && value ? ::GraphQL::Pagination::ArrayConnection.new(value, context: ctx, parent: nil, field: nil, arguments: {}) : value
                end
              end
            else
              obj, arguments, ctx = args

              # Use dataloader when available
              if ctx && ctx.respond_to?(:dataloader) && ctx.dataloader
                args_h = arguments.respond_to?(:to_h) ? arguments.to_h : {}
                loader = ctx.dataloader.with(Lighthouse::GraphQL::DataloaderSources::AssociationLoader, obj.class, assoc_name)
                value = loader.load(obj)
                if is_connection
                  value.then do |v|
                    filtered = resolver_instance.apply_where_filters(v, args_h)
                    ::GraphQL::Pagination::ArrayConnection.new(filtered, context: ctx, parent: nil, field: nil, arguments: {})
                  end
                else
                  value.then { |v| resolver_instance.apply_where_filters(v, args_h) }
                end
              elsif obj.respond_to?(assoc_name)
                args_h = arguments.respond_to?(:to_h) ? arguments.to_h : {}
                value = obj.public_send(assoc_name)
                value = resolver_instance.apply_where_filters(value, args_h)
                is_connection && value ? ::GraphQL::Pagination::ArrayConnection.new(value, context: ctx, parent: nil, field: nil, arguments: {}) : value
              else
                nil
              end
            end
          end

          # Also attach a resolve proc where supported by the GraphQL runtime.
          if @field_def.respond_to?(:resolve_proc=)
            @field_def.resolve_proc = ->(obj, arguments, ctx) do
              if ctx && ctx.respond_to?(:dataloader) && ctx.dataloader
                args_h = arguments.respond_to?(:to_h) ? arguments.to_h : {}
                loader = ctx.dataloader.with(Lighthouse::GraphQL::DataloaderSources::AssociationLoader, obj.class, assoc_name)
                result = loader.load(obj)
                if is_connection
                  result.then do |value|
                    filtered = resolver_instance.apply_where_filters(value, args_h)
                    ::GraphQL::Pagination::ArrayConnection.new(filtered, context: ctx, parent: nil, field: nil, arguments: {})
                  end
                else
                  result.then { |value| resolver_instance.apply_where_filters(value, args_h) }
                end
              elsif obj.respond_to?(assoc_name)
                args = arguments.respond_to?(:to_h) ? arguments.to_h : {}
                value = obj.public_send(assoc_name)
                value = resolver_instance.apply_where_filters(value, args)
                is_connection && value ? ::GraphQL::Pagination::ArrayConnection.new(value, context: ctx, parent: nil, field: nil, arguments: {}) : value
              else
                nil
              end
            end
          end
        end

        private

        def extract_relation_name
          # directive syntax: @hasMany(relation: "name")
          arg = @directive_node.arguments&.find { |a| a.name == 'relation' }
          return nil unless arg
          # value is AST literal node; use its value method if present
          arg.value.respond_to?(:value) ? arg.value.value : arg.value
        end
      end
    end
  end
end
