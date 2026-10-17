# frozen_string_literal: true

require 'ostruct'
require_relative 'base'
require_relative 'builder_applier'

module Lighthouse
  module GraphQL
    module DirectiveResolvers
      class PaginateDirectiveResolver < BaseDirectiveResolver
        def self.directive_name = 'paginate'
        def self.definition = 'directive @paginate(type: String, model: String) on FIELD_DEFINITION'

        class PaginatorResult
          attr_reader :paginator_info, :data

          def initialize(paginator_info:, data:)
            @paginator_info = paginator_info
            @data = data
          end

          def paginatorInfo
            @paginator_info
          end
        end

        def define_resolver(target_type_class)
          field_name = @field_def.name
          method_name = "resolve_field_#{field_name}"

          # Resolve model name now, but constantize lazily at call time so
          # Rails autoloading (Zeitwerk) can load the model after startup.
          model_name_static = extract_model_name || extract_model_name_from_field_type
          # If the field was transformed to a Paginator type (e.g. InboxPaginator),
          # derive the underlying model name by stripping a trailing "Paginator".
          model_name_static = model_name_static.to_s.sub(/Paginator\z/, '')
          # Closure to lookup the model class lazily
          model_lookup = proc { constantize_model(model_name_static) }



          # Determine whether this paginate directive requested a cursor/connection
          type_arg = extract_type_name
          is_connection_type = type_arg && %w[CONNECTION CURSOR].include?(type_arg.to_s.upcase)

          # Paginator object builder (responds to both `paginatorInfo` and `paginator_info`)
          paginator_builder = proc do |pinfo, data|
            paginator_info_object = OpenStruct.new(pinfo)
            # Ensure both camelCase and underscored-methods can be resolved by fallback
            if pinfo.is_a?(Hash)
              underscored = {}
              pinfo.each_key do |k|
                key = k.to_s
                snake = key.underscore
                underscored[snake] = pinfo[k] unless pinfo.key?(snake)
              end
              underscored.each { |kk, vv| paginator_info_object[kk] = vv }
            end

            PaginatorResult.new(paginator_info: paginator_info_object, data: data)
          end

          # Define owner singleton method to support graphql-ruby's execution
          resolver_instance = self
          field_ast_node = @field_def.ast_node
          target_type_class.define_singleton_method(method_name) do |obj, arguments, ctx|
            model_class = model_lookup.call
            return [] unless model_class

            args_h = arguments.respond_to?(:to_h) ? arguments.to_h : {}

            limit = args_h[:first]
            offset = 0
            if args_h[:after]
              begin
                decoded = Base64.decode64(args_h[:after])
                if decoded.start_with?('offset:')
                  offset = decoded.split(':', 2)[1].to_i
                end
              rescue StandardError
                offset = 0
              end
            end

            relation = model_class.all

            relation = DirectiveResolvers::BuilderApplier.apply(relation, field_ast_node, args_h, ctx, resolver_instance)

            relation = DirectiveResolvers::WhereConditionsApplier.apply(relation, args_h[:where] || args_h['where'])
            relation = relation.offset(offset) if offset > 0
            relation = relation.limit(limit) if limit

            if is_connection_type
              ::GraphQL::Pagination::ArrayConnection.new(relation, context: ctx, parent: nil, field: nil, arguments: {})
            else
              data = relation.to_a
              per_page = limit
              total = relation.count
              paginator_info = {
                count: data.size,
                currentPage: 1,
                firstItem: data.any? ? (offset + 1) : nil,
                hasMorePages: (offset + data.size) < total,
                lastItem: data.any? ? (offset + data.size) : nil,
                lastPage: per_page && per_page > 0 ? (total.to_f / per_page).ceil : 1,
                perPage: per_page || data.size,
                total: total
              }

              paginator_builder.call(paginator_info, data)
            end
          end

          # Attach a field-level resolve_proc that delegates to the generated
          # singleton resolver. This keeps runtime dispatch consistent with
          # SchemaImplementation (which checks for resolve_field_* first).
          if @field_def.respond_to?(:resolve_proc=)
            @field_def.resolve_proc = ->(obj, arguments, ctx) do
              target_type_class.public_send(method_name, obj, arguments, ctx)
            end
          end
        end

        private

        def extract_model_name
          arg = @directive_node.arguments&.find { |a| a.name == 'model' }
          return nil unless arg
          arg.value.respond_to?(:value) ? arg.value.value : arg.value
        end


        def extract_type_name
          arg = @directive_node.arguments&.find { |a| a.name == 'type' }
          return nil unless arg
          arg.value.respond_to?(:value) ? arg.value.value : arg.value
        end

        def extract_model_name_from_field_type
          unwrapped = @field_def.type.respond_to?(:unwrap) ? @field_def.type.unwrap : @field_def.type
          return unwrapped.graphql_name if unwrapped.respond_to?(:graphql_name) && unwrapped.graphql_name
          return unwrapped.name if unwrapped.respond_to?(:name) && unwrapped.name

          # fallback for late-bound signatures like "InboxPaginator!"
          @field_def.type.to_type_signature.to_s.gsub(/[!\[\]]/, '')
        end
      end
    end
  end
end
