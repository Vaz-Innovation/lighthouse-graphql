# frozen_string_literal: true

require_relative 'base'

# @find — the single record the field's argument filters select:
#
#   user(id: ID! @eq): User @find
#   userByEmail(email: String! @eq): User @find
#
# A lookup by `id` alone is batched through the Dataloader, and an `id`
# argument without a filter directive selects by primary key. More than one
# match is an error, as in PHP Lighthouse; none returns null.
class Lighthouse::GraphQL::DirectiveResolvers::FindDirectiveResolver < Lighthouse::GraphQL::DirectiveResolvers::BaseDirectiveResolver
  def self.directive_name = 'find'
  def self.definition = 'directive @find(model: String, scopes: [String!]) on FIELD_DEFINITION'

  def define_resolver(target_type_class)
    me = self
    install(target_type_class, lambda do |_obj, args, ctx|
      me.send(:find, Lighthouse::Support::Arguments.shallow(args), ctx)
    end)
  end

  protected

  def find(args, ctx)
    model = model_class
    dataloader = Lighthouse::Support::Batching.dataloader(ctx)
    return dataloader.with(Lighthouse::GraphQL::DataloaderSources::ModelLoader, model).load(args[:id]) if dataloader && batchable?(args)

    records = find_relation(model, args).limit(2).to_a
    raise ::GraphQL::ExecutionError, 'The query returned more than one result.' if records.size > 1

    records.first
  end

  # Only a lookup by `id` alone, with no scopes to apply, can be batched.
  def batchable?(args)
    args.keys == [:id] && !directive_arg('scopes')
  end

  def find_relation(model, args)
    relation = apply_scopes(model.all)
    relation = relation.where(model.primary_key => args[:id]) if args.key?(:id) && !filtered?('id')
    apply_where_filters(relation, args)
  end

  # Does the argument carry a filter directive (@eq, @where, ...)? An `id`
  # without one still selects by primary key.
  def filtered?(name)
    argument = (@field_def.ast_node&.arguments || []).find { |a| a.name == name }
    registry = Lighthouse::DirectiveRegistry.default
    argument&.directives&.any? { |d| registry.arg_builder_class(d.name) }
  end
end
