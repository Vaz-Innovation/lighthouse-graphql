# frozen_string_literal: true

require_relative 'base'
require_relative 'builder_applier'

class Lighthouse::GraphQL::DirectiveResolvers::AggregateDirectiveResolver < Lighthouse::GraphQL::DirectiveResolvers::BaseDirectiveResolver
  def self.directive_name = 'aggregate'
  def self.applies_search? = true

  # An unknown function aggregates to null.
  AGGREGATIONS = {
    'SUM' => ->(relation, column) { relation.sum(column) },
    'AVG' => ->(relation, column) { relation.average(column)&.to_f },
    'MIN' => ->(relation, column) { relation.minimum(column) },
    'MAX' => ->(relation, column) { relation.maximum(column) },
    'COUNT' => ->(relation, _column) { relation.count }
  }.freeze

  def self.definition
    <<~GRAPHQL.chomp
      """
      Return an aggregate of a column over the records of a model, or of a relation of the parent.
      The records are narrowed by the field's argument filters (@eq, @where, ...).
      An unknown function, or a failing aggregation, answers null.
      """
      directive @aggregate(
        "The aggregate to compute: SUM, AVG, MIN, MAX or COUNT (case-insensitive)."
        function: String!
        "The column to aggregate. COUNT does not use it."
        column: String
        "The class name of the model whose records to aggregate. Takes precedence over `relation`."
        model: String
        "The relation of the parent to aggregate over."
        relation: String
      ) on FIELD_DEFINITION
    GRAPHQL
  end

  def define_resolver(target_type_class)
    model_name = extract_directive_arg('model')
    relation_name = extract_directive_arg('relation')
    column_name = extract_directive_arg('column')
    function_name = extract_directive_arg('function')
    resolver_instance = self

    install(target_type_class, lambda do |obj, args, ctx|
      relation = resolver_instance.send(:aggregate_source, obj, model_name, relation_name)
      return nil unless relation

      relation = resolver_instance.apply_where_filters(relation, args, ctx)
      resolver_instance.send(:compute_aggregation, relation, column_name, function_name)
    end)
  end

  private

  def extract_directive_arg(name)
    arg = @directive_node.arguments&.find { |a| a.name == name }
    return nil unless arg

    v = arg.value.respond_to?(:value) ? arg.value.value : arg.value
    v.is_a?(::GraphQL::Language::Nodes::Enum) ? v.name : v
  end

  # The model's table when `model:` is given, else the parent's relation.
  def aggregate_source(obj, model_name, relation_name)
    if model_name
      constantize_model(model_name)&.all
    elsif relation_name && obj.respond_to?(relation_name)
      obj.public_send(relation_name)
    end
  end

  def compute_aggregation(relation, column, function_name)
    return nil unless relation.respond_to?(:any?)

    AGGREGATIONS[function_name.to_s.upcase]&.call(relation, column.to_s)
  rescue StandardError
    nil
  end

  def install_resolve_proc(method_name)
    return unless @field_def.respond_to?(:resolve_proc=)

    @field_def.resolve_proc = lambda { |obj, arguments, ctx|
      target_type_class = self.class
      target_type_class.public_send(method_name, obj, arguments, ctx) if target_type_class.respond_to?(method_name)
    }
  end
end
