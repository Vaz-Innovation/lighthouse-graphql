# frozen_string_literal: true

require_relative 'base'

# Resolves a Query or Mutation field that has no resolving directive by
# convention, as PHP Lighthouse does: `Query.latestPosts` resolves to
# `Resolvers::LatestPosts` (a GraphQL::Schema::Resolver, by graphql-ruby's
# convention a Resolvers::BaseResolver), `Mutation.publishPost` to
# `Mutations::PublishPost` (a GraphQL::Schema::Mutation), looked up in
# Config.namespaces[:queries] / [:mutations] at call time so code reloading
# keeps working. Not a directive: SchemaGenerator installs it.
class Lighthouse::GraphQL::DirectiveResolvers::ConventionResolver < Lighthouse::GraphQL::DirectiveResolvers::BaseDirectiveResolver
  # `base`: the class the schema's base_types require the class to inherit from.
  def initialize(field_def, type_def, kind, base = nil)
    super(field_def, type_def, nil)
    @kind = kind
    @base = base
  end

  def define_resolver(target_type_class)
    Lighthouse::GraphQL::ResolveInfo.request_lookahead(@field_def)
    me = self
    inner = capture_inner(target_type_class)

    install(target_type_class, lambda do |obj, args, ctx|
      me.send(:resolve_by_convention, inner, obj, args, ctx)
    end)
  end

  ROOT_KINDS = { 'Query' => :queries, 'Mutation' => :mutations }.freeze

  # :queries / :mutations for the conventional root type names. The
  # SchemaGenerator passes the schema's actual roots as `root_kind:`.
  def self.root_kind_of(type)
    ROOT_KINDS[type.respond_to?(:graphql_name) ? type.graphql_name : type.to_s]
  end

  # The class a root field resolves to, without its namespace: `LatestPosts`
  # for `latestPosts`.
  def self.class_name_for(field_def)
    field_def.name.to_s.camelize
  end

  private

  def resolve_by_convention(inner, obj, args, ctx)
    namespaces = Lighthouse::Config.namespaces[@kind]
    klass = Lighthouse::Support::ModelResolver.constantize(class_name, namespaces: namespaces, fallback: false)
    return missing(namespaces, inner, obj, args, ctx) unless klass

    unless Lighthouse::GraphQL::ResolverDispatch.graphql_resolver?(klass)
      raise Lighthouse::DefinitionError,
            "#{klass} resolves #{location}, so it must inherit from GraphQL::Schema::Resolver " \
            '(or GraphQL::Schema::Mutation).'
    end
    Lighthouse::GraphQL::ResolverBases.check!(klass, @base, location)

    Lighthouse::GraphQL::ResolverDispatch.call(klass, Lighthouse::GraphQL::ResolveInfo.for(@field_def, @type_def, obj, args, ctx))
  end

  # No class: the root object may still answer (a custom root_value);
  # otherwise report the misconfiguration through Config.on_error.
  def missing(namespaces, inner, obj, args, ctx)
    return inner.call(obj, args, ctx) if obj && !obj.is_a?(Hash) && obj.respond_to?(@field_def.name)

    expected = Array(namespaces).map { |ns| "#{ns}::#{class_name}" }.join(' or ')
    Lighthouse::Config.handle_error(
      Lighthouse::DefinitionError.new("#{location} has no resolver: define #{expected}, or add a resolving directive."),
      ctx
    )
    nil
  end

  def class_name
    @class_name ||= self.class.class_name_for(@field_def)
  end

  def location
    @location ||= "#{@type_def.graphql_name}.#{@field_def.name}"
  end
end
