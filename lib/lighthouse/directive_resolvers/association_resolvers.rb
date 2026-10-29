# frozen_string_literal: true

require_relative 'base'

module Lighthouse::GraphQL::DirectiveResolvers
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
  # Pages are batched too: every parent's page in one query, and the totals
  # in another (see RelationBatch).
  class AssociationDirectiveResolver < Lighthouse::GraphQL::DirectiveResolvers::BaseDirectiveResolver
    CONDITION_DIRECTIVES = %w[whereConditions whereHasConditions].freeze

    def self.collection? = false

    # The directive's SDL: `description`, then the arguments of a relationship —
    # and, on a collection, the pagination ones.
    def self.definition(name = directive_name, description = self::DESCRIPTION)
      arguments = [RELATION_ARGUMENT, SCOPES_ARGUMENT]
      arguments += PAGINATION_ARGUMENTS if collection?
      <<~GRAPHQL.chomp
        """
        #{description}
        """
        directive @#{name}(
        #{arguments.join("\n")}
        ) on FIELD_DEFINITION
      GRAPHQL
    end

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

      return paginate(obj, name, args, ctx) if pagination_type
      return constrained(association_scope(obj, name), args, ctx) if constrained?(args)

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

    # Scopes, a query directive on the field (@builder, @orderBy(column:)) or a
    # supplied argument with a filter directive need a query of their own
    # instead of the batched load.
    def constrained?(args)
      directive_arg('scopes') || Lighthouse::GraphQL::DirectiveResolvers::BuilderApplier.any?(@field_def.ast_node) || filtered?(args)
    end

    def filtered?(args)
      registry = Lighthouse::DirectiveRegistry.default
      (@field_def.ast_node&.arguments || []).any? do |argument|
        args.key?(argument.name.underscore.to_sym) && argument.directives.any? { |d| filter_directive?(registry, d) }
      end
    end

    # An argument builder (@eq, @where, ...) or a where-conditions filter.
    def filter_directive?(registry, directive)
      registry.arg_builder_class(directive.name) || CONDITION_DIRECTIVES.include?(directive.name)
    end

    def constrained(relation, args, ctx)
      relation = apply_where_filters(scoped(relation), args, ctx)
      self.class.collection? ? relation : relation.first
    end

    def paginate(obj, name, args, ctx)
      limits = { default_count: directive_arg('defaultCount') }
      limits[:max_count] = directive_arg('maxCount') || :unlimited if directive_given?('maxCount')
      Lighthouse::GraphQL::Pagination.paginate(paginated_list(obj, name, args, ctx), pagination_type, args, limits)
    end

    # This parent's page, batched with its siblings' when the Dataloader can.
    def paginated_list(obj, name, args, ctx)
      dataloader = Lighthouse::Support::Batching.dataloader(ctx)
      batch = dataloader && Lighthouse::GraphQL::RelationBatch.for(obj, name, args, self, ctx)
      return Lighthouse::GraphQL::Pagination::BatchedList.new(batch, obj, dataloader) if batch

      decorate_relation(association_scope(obj, name), args, ctx)
    end

    public

    # The field's scopes and filters on the association's query, for one
    # parent or a RelationBatch of them.
    def decorate_relation(relation, args, ctx)
      apply_where_filters(scoped(relation), args, ctx)
    end

    protected

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

  PAGINATION_ARGUMENTS = [
    BaseDirectiveResolver.argument_sdl(
      'type: PaginateType',
      'How to paginate the list: PAGINATOR, SIMPLE or CONNECTION. Without it, the whole list is returned.'
    ),
    BaseDirectiveResolver.argument_sdl(
      'defaultCount: Int',
      'The page size when the client omits `first`. Defaults to Config.pagination_default_count.'
    ),
    BaseDirectiveResolver.argument_sdl(
      'maxCount: Int',
      'The most records the client may ask for with `first`; null for no limit. Defaults to Config.pagination_max_count.'
    )
  ].freeze

  class HasManyDirectiveResolver < AssociationDirectiveResolver
    def self.collection? = true
    def self.directive_name = 'hasMany'
    DESCRIPTION = <<~TEXT.chomp
      Resolve a one-to-many association of the parent (`has_many`) as a list,
      batch-loaded so that listing it for many parents is not an N+1.
      With `type`, the list is paginated.
    TEXT
  end

  class BelongsToManyDirectiveResolver < AssociationDirectiveResolver
    def self.collection? = true
    def self.directive_name = 'belongsToMany'
    DESCRIPTION = <<~TEXT.chomp
      Resolve a many-to-many association of the parent (`has_and_belongs_to_many`) as a list,
      batch-loaded so that listing it for many parents is not an N+1.
      With `type`, the list is paginated.
    TEXT
  end

  class MorphManyDirectiveResolver < AssociationDirectiveResolver
    def self.collection? = true
    def self.directive_name = 'morphMany'
    DESCRIPTION = <<~TEXT.chomp
      Resolve a polymorphic one-to-many association of the parent (`has_many ..., as:`) as a list,
      batch-loaded so that listing it for many parents is not an N+1.
      With `type`, the list is paginated.
    TEXT
  end

  class MorphToManyDirectiveResolver < AssociationDirectiveResolver
    def self.collection? = true
    def self.directive_name = 'morphToMany'
    DESCRIPTION = <<~TEXT.chomp
      Resolve a polymorphic many-to-many association of the parent as a list,
      batch-loaded so that listing it for many parents is not an N+1.
      With `type`, the list is paginated.
    TEXT
  end

  class HasOneDirectiveResolver < AssociationDirectiveResolver
    def self.directive_name = 'hasOne'
    DESCRIPTION = <<~TEXT.chomp
      Resolve a one-to-one association of the parent (`has_one`),
      batch-loaded so that loading it for many parents is not an N+1.
    TEXT
  end

  class MorphOneDirectiveResolver < AssociationDirectiveResolver
    def self.directive_name = 'morphOne'
    DESCRIPTION = <<~TEXT.chomp
      Resolve a polymorphic one-to-one association of the parent (`has_one ..., as:`),
      batch-loaded so that loading it for many parents is not an N+1.
    TEXT
  end

  class BelongsToDirectiveResolver < AssociationDirectiveResolver
    def self.directive_name = 'belongsTo'
    DESCRIPTION = <<~TEXT.chomp
      Resolve the inverse of a one-to-one or one-to-many association (`belongs_to`),
      batch-loaded so that loading it for many parents is not an N+1.
    TEXT
  end

  class MorphToDirectiveResolver < AssociationDirectiveResolver
    def self.directive_name = 'morphTo'
    DESCRIPTION = <<~TEXT.chomp
      Resolve a polymorphic inverse association of the parent (`belongs_to ..., polymorphic: true`),
      batch-loaded so that loading it for many parents is not an N+1.
    TEXT
  end
end
