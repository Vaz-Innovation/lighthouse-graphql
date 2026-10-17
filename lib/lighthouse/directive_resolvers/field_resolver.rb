# frozen_string_literal: true

require_relative 'base'

class Lighthouse::GraphQL::DirectiveResolvers::FieldDirectiveResolver < Lighthouse::GraphQL::DirectiveResolvers::BaseDirectiveResolver
  def self.directive_name = 'field'
  def self.definition = 'directive @field(resolver: String, class: String) on FIELD_DEFINITION'

  # On Query and Mutation the class is looked up in the queries / mutations
  # namespaces; on any other type, in Config.resolver_namespaces.
  def define_resolver(target_type_class)
    field_def = @field_def
    class_name = extract_directive_arg('resolver') || extract_directive_arg('class')
    kind = root_kind(target_type_class)

    install(target_type_class, lambda do |obj, args, ctx|
      namespaces = kind ? Lighthouse::Config.namespaces[kind] : Lighthouse::Config.resolver_namespaces
      klass = Lighthouse::Support::ModelResolver.constantize(class_name, namespaces: namespaces)
      next nil unless klass

      Lighthouse::GraphQL::ResolverDispatch.call(klass, field_def, obj, args, ctx)
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
