# frozen_string_literal: true

require_relative 'base'
require_relative 'builder_applier'

# @count(model: "Model", relation: "assoc") — return the number of records.
# Counts `Model.all` when `model:` is given, otherwise the named relation on
# the parent object (or a relation matching the field name). Honors `scopes:`, @builder
# and where/argument filters before counting.
class Lighthouse::GraphQL::DirectiveResolvers::CountDirectiveResolver < Lighthouse::GraphQL::DirectiveResolvers::BaseDirectiveResolver
  def self.directive_name = 'count'
  def self.applies_search? = true

  def self.definition
    <<~GRAPHQL.chomp
      """
      Return the number of records: of a model's table, or of a relation of the parent.
      The count honors `scopes`, @builder and the field's argument filters (@eq, @where, ...).
      """
      directive @count(
        "The class name of the model whose records to count. Takes precedence over `relation`."
        model: String
        "The relation of the parent to count. Defaults to the field's name, when the parent has it."
        relation: String
      #{SCOPES_ARGUMENT}
      ) on FIELD_DEFINITION
    GRAPHQL
  end

  def define_resolver(target_type_class)
    model_name = directive_arg('model')
    relation_name = directive_arg('relation')
    me = self

    install(target_type_class, lambda do |obj, arguments, ctx|
      me.send(:count_records, me.send(:countable, obj, model_name, relation_name), arguments, ctx)
    end)
  end

  private

  def directive_arg(name)
    Lighthouse::Support::DirectiveArgs.literal(@directive_node, name)
  end

  def countable(obj, model_name, relation_name)
    field_name = @field_def.name
    if model_name
      constantize_model(model_name)&.all
    elsif relation_name && obj.respond_to?(relation_name)
      obj.public_send(relation_name)
    elsif obj.respond_to?(field_name)
      obj.public_send(field_name)
    end
  end

  def count_records(relation, arguments, ctx)
    return 0 unless relation.respond_to?(:count)

    args_h = arguments.respond_to?(:to_h) ? arguments.to_h : {}
    relation = apply_scopes(relation)
    relation = apply_where_filters(relation, args_h, ctx)
    relation.count
  end
end
