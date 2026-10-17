# frozen_string_literal: true

require_relative 'base'

module Lighthouse
  module GraphQL
    module DirectiveResolvers
      # Relationship directives: resolve an ActiveRecord association of the
      # parent. `relation:` names it (default: the field name in snake_case);
      # `scopes:` applies model scopes. The Morph* directives are PHP Lighthouse's
      # names for polymorphic associations, which ActiveRecord resolves the same way.
      #
      # Without query constraints the association is batch-loaded through the
      # Dataloader (one query per association per batch). Collection directives
      # take PHP Lighthouse's `type:` — PAGINATOR, SIMPLE or CONNECTION — to
      # paginate (see Directives::PaginationManipulator), and the field's argument
      # filters (@eq, @where, @orderBy, ...) apply to the association's query.
      class AssociationDirectiveResolver < BaseDirectiveResolver
        def self.collection? = false

        def define_resolver(target_type_class)
          me = self
          install(target_type_class, lambda do |obj, args, ctx|
            next nil if obj.nil?

            me.send(:resolve_association, obj, Lighthouse::Support::Arguments.shallow(args), ctx)
          end)
        end

        protected

        def resolve_association(obj, args, ctx)
          name = association_name
          return nil unless obj.respond_to?(name)

          return paginate(association_scope(obj, name), args) if pagination_type
          return constrained(association_scope(obj, name), args) if constrained?(args)

          dataloader = Lighthouse::Support::Batching.dataloader(ctx)
          return obj.public_send(name) unless dataloader && obj.class.respond_to?(:reflect_on_association)

          dataloader.with(Lighthouse::GraphQL::DataloaderSources::AssociationLoader, obj.class, name).load(obj)
        end

        def association_name
          (directive_arg('relation') || Lighthouse::Support::Naming.attribute(@field_def.name)).to_s
        end

        def pagination_type
          self.class.collection? && directive_arg('type')&.to_s&.upcase
        end

        # Scopes or a supplied argument with a filter directive need a query of
        # their own instead of the batched load.
        def constrained?(args)
          return true if directive_arg('scopes')

          registry = Lighthouse::DirectiveRegistry.default
          (@field_def.ast_node&.arguments || []).any? do |argument|
            args.key?(argument.name.underscore.to_sym) &&
              argument.directives.any? { |d| registry.arg_builder_class(d.name) || %w[whereConditions whereHasConditions].include?(d.name) }
          end
        end

        def constrained(relation, args)
          relation = apply_where_filters(scoped(relation), args)
          self.class.collection? ? relation : relation.first
        end

        def paginate(value, args)
          limits = { default_count: directive_arg('defaultCount') }
          limits[:max_count] = directive_arg('maxCount') || :unlimited if directive_given?('maxCount')
          Pagination.paginate(apply_where_filters(scoped(value), args), pagination_type, args, limits)
        end

        # The association as a query (for a singular association too), so scopes
        # and filters can be applied to it.
        def association_scope(obj, name)
          obj.respond_to?(:association) ? obj.association(name.to_sym).scope : obj.public_send(name)
        end

        def scoped(relation)
          Array(directive_arg('scopes')).reduce(relation) { |acc, scope| acc.public_send(scope) }
        end

        def directive_given?(name)
          @directive_node&.arguments&.any? { |a| a.name == name }
        end
      end

      COLLECTION_ARGUMENTS = 'relation: String, scopes: [String!], type: PaginateType, defaultCount: Int, maxCount: Int'

      class HasManyDirectiveResolver < AssociationDirectiveResolver
        def self.collection? = true
        def self.directive_name = 'hasMany'
        def self.definition = "directive @hasMany(#{COLLECTION_ARGUMENTS}) on FIELD_DEFINITION"
      end

      class BelongsToManyDirectiveResolver < AssociationDirectiveResolver
        def self.collection? = true
        def self.directive_name = 'belongsToMany'
        def self.definition = "directive @belongsToMany(#{COLLECTION_ARGUMENTS}) on FIELD_DEFINITION"
      end

      class MorphManyDirectiveResolver < AssociationDirectiveResolver
        def self.collection? = true
        def self.directive_name = 'morphMany'
        def self.definition = "directive @morphMany(#{COLLECTION_ARGUMENTS}) on FIELD_DEFINITION"
      end

      class MorphToManyDirectiveResolver < AssociationDirectiveResolver
        def self.collection? = true
        def self.directive_name = 'morphToMany'
        def self.definition = "directive @morphToMany(#{COLLECTION_ARGUMENTS}) on FIELD_DEFINITION"
      end

      class HasOneDirectiveResolver < AssociationDirectiveResolver
        def self.directive_name = 'hasOne'
        def self.definition = 'directive @hasOne(relation: String, scopes: [String!]) on FIELD_DEFINITION'
      end

      class MorphOneDirectiveResolver < AssociationDirectiveResolver
        def self.directive_name = 'morphOne'
        def self.definition = 'directive @morphOne(relation: String, scopes: [String!]) on FIELD_DEFINITION'
      end

      class BelongsToDirectiveResolver < AssociationDirectiveResolver
        def self.directive_name = 'belongsTo'
        def self.definition = 'directive @belongsTo(relation: String, scopes: [String!]) on FIELD_DEFINITION'
      end

      class MorphToDirectiveResolver < AssociationDirectiveResolver
        def self.directive_name = 'morphTo'
        def self.definition = 'directive @morphTo(relation: String, scopes: [String!]) on FIELD_DEFINITION'
      end
    end
  end
end
