# frozen_string_literal: true

module Lighthouse
  module GraphQL
    module Directives
      # AST transformer that converts list-typed relationship fields annotated
      # with relationship directives (e.g. @hasMany, @paginate) into
      # Connection/Paginator return types and injects pagination arguments.
      class RelationDirective
        DIRECTIVE_NAMES = %w[hasMany belongsToMany hasManyThrough paginate all].freeze

        def self.manipulate(sdl)
          return sdl unless sdl.is_a?(String) && !sdl.empty?

          begin
            document = ::GraphQL::Language::Parser.parse(sdl)
          rescue StandardError => e
            warn("Lighthouse::GraphQL::Directives::RelationDirective: parse failed: #{e.class}: #{e.message}")
            return sdl
          end

          existing_def_names = document.definitions.filter_map { |d| d.respond_to?(:name) ? d.name : nil }
          produced_inner_types = []

          document.definitions.each do |definition|
            next unless definition.is_a?(::GraphQL::Language::Nodes::ObjectTypeDefinition)

            definition.fields.each do |field|
              next unless field.type
              next if field.directives.nil? || field.directives.empty?
              next unless field.directives.any? { |d| DIRECTIVE_NAMES.include?(d.name) }

              list_inner = list_inner_named_type(field.type)
              next unless list_inner

              produce_connection, produce_paginator = pagination_kind_for(field.directives)
              next unless produce_connection || produce_paginator

              produced_inner_types << list_inner unless produced_inner_types.include?(list_inner)

              # Replace list type with Connection/Paginator return type, preserving outer nullability.
              new_named_type =
                if produce_connection
                  "#{list_inner}Connection"
                else
                  "#{list_inner}Paginator"
                end

              field.instance_variable_set(:@type, replace_with_named_type(field.type, new_named_type))

              if produce_connection
                field.instance_variable_set(:@arguments, ensure_connection_arguments(field.arguments || []))
              end
            end
          end

          return sdl if produced_inner_types.empty?

          # Add Connection/Edge/Paginator utility types where missing.
          new_defs = []
          produced_inner_types.each do |inner|
            conn_name = "#{inner}Connection"
            edge_name = "#{inner}Edge"
            paginator_name = "#{inner}Paginator"

            unless existing_def_names.include?(conn_name)
              new_defs << build_connection_type(conn_name, edge_name, inner)
              existing_def_names << conn_name
            end

            unless existing_def_names.include?(edge_name)
              new_defs << build_edge_type(edge_name, inner)
              existing_def_names << edge_name
            end

            unless existing_def_names.include?(paginator_name)
              new_defs << build_paginator_type(paginator_name, inner)
              existing_def_names << paginator_name
            end
          end

          unless existing_def_names.include?('PaginatorInfo')
            new_defs << build_paginator_info_type
            existing_def_names << 'PaginatorInfo'
          end

          unless existing_def_names.include?('PageInfo')
            new_defs << build_page_info_type
            existing_def_names << 'PageInfo'
          end

          modified_sdl = ::GraphQL::Language::Printer.new.print(document)
          modified_sdl + "\n\n" + new_defs.map { |d| ::GraphQL::Language::Printer.new.print(d) }.join("\n\n")
        end

        def self.pagination_kind_for(directives)
          # For relation directives, always use Connection.
          if directives.any? { |d| d.name != 'paginate' && DIRECTIVE_NAMES.include?(d.name) }
            return [true, false]
          end

          paginate = directives.find { |d| d.name == 'paginate' }
          return [false, false] unless paginate

          type_arg = directive_arg_literal(paginate, 'type')&.to_s&.upcase
          if %w[CONNECTION CURSOR].include?(type_arg)
            [true, false]
          else
            [false, true]
          end
        end

        def self.directive_arg_literal(directive, name)
          arg = directive.arguments&.find { |a| a.name == name }
          return nil unless arg
          arg.value.respond_to?(:value) ? arg.value.value : arg.value
        end

        def self.list_inner_named_type(type_node)
          case type_node
          when ::GraphQL::Language::Nodes::NonNullType
            list_inner_named_type(type_node.of_type)
          when ::GraphQL::Language::Nodes::ListType
            unwrap_named_type(type_node.of_type)
          else
            nil
          end
        end

        def self.unwrap_named_type(type_node)
          case type_node
          when ::GraphQL::Language::Nodes::NonNullType
            unwrap_named_type(type_node.of_type)
          when ::GraphQL::Language::Nodes::TypeName
            type_node.name
          else
            nil
          end
        end

        def self.replace_with_named_type(type_node, new_name)
          new_type = ::GraphQL::Language::Nodes::TypeName.new(name: new_name)
          if type_node.is_a?(::GraphQL::Language::Nodes::NonNullType)
            ::GraphQL::Language::Nodes::NonNullType.new(of_type: new_type)
          else
            new_type
          end
        end

        def self.ensure_connection_arguments(existing_args)
          existing_names = existing_args.map(&:name)
          args = existing_args.map do |arg|
            next arg unless %w[after before first last].include?(arg.name)
            next arg if arg.description && !arg.description.empty?

            ::GraphQL::Language::Nodes::InputValueDefinition.new(
              name: arg.name,
              type: arg.type,
              directives: arg.directives || [],
              default_value: arg.default_value,
              description: connection_arg_description(arg.name)
            )
          end

          %w[after before first last].each do |name|
            next if existing_names.include?(name)

            type =
              if %w[first last].include?(name)
                ::GraphQL::Language::Nodes::TypeName.new(name: 'Int')
              else
                ::GraphQL::Language::Nodes::TypeName.new(name: 'String')
              end

            args << ::GraphQL::Language::Nodes::InputValueDefinition.new(
              name: name,
              type: type,
              directives: [],
              default_value: nil,
              description: connection_arg_description(name)
            )
          end

          args
        end

        def self.build_connection_type(conn_name, edge_name, node_name)
          ::GraphQL::Language::Nodes::ObjectTypeDefinition.new(
            name: conn_name,
            interfaces: [],
            directives: [],
            description: "The connection type for #{node_name}.",
            fields: [
              ::GraphQL::Language::Nodes::FieldDefinition.new(
                name: 'edges',
                type: ::GraphQL::Language::Nodes::ListType.new(of_type: ::GraphQL::Language::Nodes::TypeName.new(name: edge_name)),
                arguments: [],
                directives: [],
                description: 'A list of edges.'
              ),
              ::GraphQL::Language::Nodes::FieldDefinition.new(
                name: 'nodes',
                type: ::GraphQL::Language::Nodes::ListType.new(of_type: ::GraphQL::Language::Nodes::TypeName.new(name: node_name)),
                arguments: [],
                directives: [],
                description: 'A list of nodes.'
              ),
              ::GraphQL::Language::Nodes::FieldDefinition.new(
                name: 'pageInfo',
                type: ::GraphQL::Language::Nodes::NonNullType.new(of_type: ::GraphQL::Language::Nodes::TypeName.new(name: 'PageInfo')),
                arguments: [],
                directives: [],
                description: 'Information to aid in pagination.'
              )
            ]
          )
        end

        def self.build_edge_type(edge_name, node_name)
          ::GraphQL::Language::Nodes::ObjectTypeDefinition.new(
            name: edge_name,
            interfaces: [],
            directives: [],
            description: 'An edge in a connection.',
            fields: [
              ::GraphQL::Language::Nodes::FieldDefinition.new(
                name: 'cursor',
                type: ::GraphQL::Language::Nodes::NonNullType.new(of_type: ::GraphQL::Language::Nodes::TypeName.new(name: 'String')),
                arguments: [],
                directives: [],
                description: 'A cursor for use in pagination.'
              ),
              ::GraphQL::Language::Nodes::FieldDefinition.new(
                name: 'node',
                type: ::GraphQL::Language::Nodes::TypeName.new(name: node_name),
                arguments: [],
                directives: [],
                description: 'The item at the end of the edge.'
              )
            ]
          )
        end

        def self.build_paginator_type(paginator_name, inner_name)
          ::GraphQL::Language::Nodes::ObjectTypeDefinition.new(
            name: paginator_name,
            interfaces: [],
            directives: [],
            description: "A paginated list of #{inner_name} items.",
            fields: [
              ::GraphQL::Language::Nodes::FieldDefinition.new(
                name: 'paginatorInfo',
                type: ::GraphQL::Language::Nodes::NonNullType.new(of_type: ::GraphQL::Language::Nodes::TypeName.new(name: 'PaginatorInfo')),
                arguments: [],
                directives: [],
                description: 'Pagination information about the list of items.'
              ),
              ::GraphQL::Language::Nodes::FieldDefinition.new(
                name: 'data',
                type: ::GraphQL::Language::Nodes::ListType.new(of_type: ::GraphQL::Language::Nodes::TypeName.new(name: inner_name)),
                arguments: [],
                directives: [],
                description: "A list of #{inner_name} items."
              )
            ]
          )
        end

        def self.build_paginator_info_type
          ::GraphQL::Language::Nodes::ObjectTypeDefinition.new(
            name: 'PaginatorInfo',
            interfaces: [],
            directives: [],
            description: 'Information about pagination in a paginator.',
            fields: [
              field_def('count', 'Int', non_null: true),
              field_def('currentPage', 'Int', non_null: true),
              field_def('firstItem', 'Int'),
              field_def('hasMorePages', 'Boolean', non_null: true),
              field_def('lastItem', 'Int'),
              field_def('lastPage', 'Int', non_null: true),
              field_def('perPage', 'Int', non_null: true),
              field_def('total', 'Int', non_null: true)
            ]
          )
        end

        def self.build_page_info_type
          # Minimal Relay PageInfo. GraphQL-Ruby can also supply this via Relay,
          # but SDL-first apps may not include it.
          ::GraphQL::Language::Nodes::ObjectTypeDefinition.new(
            name: 'PageInfo',
            interfaces: [],
            directives: [],
            description: nil,
            fields: [
              field_def('hasNextPage', 'Boolean', non_null: true),
              field_def('hasPreviousPage', 'Boolean', non_null: true),
              field_def('startCursor', 'String'),
              field_def('endCursor', 'String')
            ]
          )
        end

        def self.field_def(name, type_name, non_null: false)
          type = ::GraphQL::Language::Nodes::TypeName.new(name: type_name)
          type = ::GraphQL::Language::Nodes::NonNullType.new(of_type: type) if non_null
          ::GraphQL::Language::Nodes::FieldDefinition.new(
            name: name,
            type: type,
            arguments: [],
            directives: [],
            description: nil
          )
        end

        def self.connection_arg_description(name)
          case name
          when 'after'
            'Returns the elements in the list that come after the specified cursor.'
          when 'before'
            'Returns the elements in the list that come before the specified cursor.'
          when 'first'
            'Returns the first _n_ elements from the list.'
          when 'last'
            'Returns the last _n_ elements from the list.'
          end
        end
      end
    end
  end
end
