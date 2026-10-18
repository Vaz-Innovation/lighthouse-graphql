# frozen_string_literal: true

require_relative 'base'

class Lighthouse::GraphQL::DirectiveResolvers::FieldDirectiveResolver < Lighthouse::GraphQL::DirectiveResolvers::BaseDirectiveResolver
  def self.directive_name = 'field'

  def self.definition
    <<~GRAPHQL.chomp
      """
      Assign a resolver to a field: a class, or a class and a method separated by `@`
      ("Statistics@users_total"). Without a method, the class resolves, or is called.
      """
      directive @field(resolver: String, class: String) on FIELD_DEFINITION
    GRAPHQL
  end

  # ["Statistics", "users_total"] for "Statistics@users_total"; [name, nil] without `@`.
  def self.reference(resolver)
    class_name, method = resolver.to_s.split('@', 2)
    [class_name, method.presence]
  end

  # The class @field names. On Query and Mutation (`kind` :queries / :mutations)
  # it is looked up in that kind's namespaces, nested names included
  # (`Feeds::Home` is Resolvers::Feeds::Home), then as written. On any other
  # type, in the resolvers namespace first (`Posts::TagsCount` is
  # Resolvers::Posts::TagsCount), then in Config.resolver_namespaces. Looked up
  # at call time, so code reloading keeps working.
  def self.lookup(class_name, kind)
    resolver = Lighthouse::Support::ModelResolver
    return resolver.constantize(class_name, namespaces: Lighthouse::Config.namespaces[kind], nested: true) if kind

    resolver.constantize(class_name, namespaces: Lighthouse::Config.namespaces[:queries], nested: true, fallback: false) ||
      resolver.constantize(class_name, namespaces: Lighthouse::Config.resolver_namespaces)
  end

  def define_resolver(target_type_class)
    Lighthouse::GraphQL::ResolveInfo.request_lookahead(@field_def)
    field_def = @field_def
    class_name, method = self.class.reference(extract_directive_arg('resolver') || extract_directive_arg('class'))
    kind = root_kind(target_type_class)

    install(target_type_class, lambda do |obj, args, ctx|
      klass = Lighthouse::GraphQL::DirectiveResolvers::FieldDirectiveResolver.lookup(class_name, kind)
      next nil unless klass

      info = Lighthouse::GraphQL::ResolveInfo.for(field_def, target_type_class, obj, args, ctx)
      Lighthouse::GraphQL::ResolverDispatch.call(klass, info, method: method)
    end)
  end

  private

  def extract_directive_arg(name)
    arg = @directive_node.arguments&.find { |a| a.name == name }
    return nil unless arg

    arg.value.respond_to?(:value) ? arg.value.value : arg.value
  end

  def root_kind(target_type_class)
    @opts[:root_kind] || Lighthouse::GraphQL::DirectiveResolvers::ConventionResolver.root_kind_of(target_type_class)
  end
end
