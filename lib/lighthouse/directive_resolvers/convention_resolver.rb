# frozen_string_literal: true

require_relative 'base'

module Lighthouse
  module GraphQL
    module DirectiveResolvers
      # Resolves a Query or Mutation field that has no resolving directive by
      # convention, as PHP Lighthouse does: `Query.latestPosts` resolves to
      # `Queries::LatestPosts` (a GraphQL::Schema::Resolver), `Mutation.publishPost`
      # to `Mutations::PublishPost` (a GraphQL::Schema::Mutation), looked up in
      # Config.namespaces[:queries] / [:mutations] at call time so code reloading
      # keeps working. Not a directive: SchemaGenerator installs it.
      class ConventionResolver < BaseDirectiveResolver
        def initialize(field_def, type_def, kind)
          super(field_def, type_def, nil)
          @kind = kind
        end

        def define_resolver(target_type_class)
          field_def = @field_def
          kind = @kind
          class_name = @field_def.name.to_s.camelize
          location = "#{@type_def.graphql_name}.#{@field_def.name}"
          inner = capture_inner(target_type_class)

          install(target_type_class, lambda do |obj, args, ctx|
            namespaces = Lighthouse::Config.namespaces[kind]
            klass = Lighthouse::Support::ModelResolver.constantize(class_name, namespaces: namespaces, fallback: false)
            next ConventionResolver.missing(location, class_name, namespaces, inner, obj, args, ctx) unless klass

            unless ResolverDispatch.graphql_resolver?(klass)
              raise Lighthouse::DefinitionError,
                    "#{klass} resolves #{location}, so it must inherit from GraphQL::Schema::Resolver " \
                    '(or GraphQL::Schema::Mutation).'
            end

            ResolverDispatch.call(klass, field_def, obj, args, ctx)
          end)
        end

        ROOT_KINDS = { 'Query' => :queries, 'Mutation' => :mutations }.freeze

        # :queries / :mutations for the conventional root type names. The
        # SchemaGenerator passes the schema's actual roots as `root_kind:`.
        def self.root_kind_of(type)
          ROOT_KINDS[type.respond_to?(:graphql_name) ? type.graphql_name : type.to_s]
        end

        # No class: the root object may still answer (a custom root_value);
        # otherwise report the misconfiguration through Config.on_error.
        def self.missing(location, class_name, namespaces, inner, obj, args, ctx)
          return inner.call(obj, args, ctx) if obj && !obj.is_a?(Hash) && obj.respond_to?(location.split('.').last)

          expected = Array(namespaces).map { |ns| "#{ns}::#{class_name}" }.join(' or ')
          Lighthouse::Config.handle_error(
            Lighthouse::DefinitionError.new("#{location} has no resolver: define #{expected}, or add a resolving directive."),
            ctx
          )
          nil
        end
      end
    end
  end
end
