# frozen_string_literal: true

require_relative 'base'
require_relative 'builder_applier'

class Lighthouse::GraphQL::DirectiveResolvers::AllDirectiveResolver < Lighthouse::GraphQL::DirectiveResolvers::BaseDirectiveResolver
  def self.directive_name = 'all'
  def self.applies_search? = true
  def self.takes_search_results?(*) = true

  def self.definition
    <<~GRAPHQL.chomp
      """
      Get a collection of models as the field result: all the model's records,
      narrowed by `scopes`, @builder and the field's argument filters (@eq, @where, ...).
      """
      directive @all(
      #{MODEL_ARGUMENT}
      #{SCOPES_ARGUMENT}
      ) on FIELD_DEFINITION
    GRAPHQL
  end

  def define_resolver(target_type_class)
    model_class = constantize_model(extract_model_name || @field_def.type.unwrap.graphql_name)
    me = self

    install(target_type_class, lambda do |_obj, arguments, ctx|
      me.send(:resolve_all, model_class, arguments, ctx)
    end)
  end

  private

  def resolve_all(model_class, arguments, ctx)
    return [] unless model_class

    # apply simple pagination args if present
    args = arguments.respond_to?(:to_h) ? arguments.to_h : {}
    relation = apply_scopes(model_class.all)

    relation = apply_where_filters(relation, args, ctx, search: :model)
    return search_records(relation, args, ctx) if relation.is_a?(Lighthouse::Search::Result)

    relation = relation.limit(args[:first]) if args[:first]
    relation = relation.offset(args[:offset]) if args[:offset]
    relation
  end

  # The records a search found: as many as the client asks for (`first`, an
  # argument's @limit, which cuts them after), else every one; and an error next
  # to them when fewer came back while more match (Search::Result::READ_LIMIT
  # in one read, the result window).
  def search_records(result, args, ctx)
    wanted = [args[:first], limit_of(args)].compact.min
    records = result.records(first: wanted, offset: args[:offset])
    ctx.add_error(::GraphQL::ExecutionError.new(truncation(result, records, args[:offset] || 0))) if result.truncated? && ctx.respond_to?(:add_error)
    records
  end

  # The client's @limit (without `builder: true`), when it is one LimitResolver can cut to.
  def limit_of(args)
    keyword = Lighthouse::GraphQL::DirectiveResolvers::LimitResolver.keyword(@field_def)
    limit = args[keyword] if keyword
    limit if limit.is_a?(Integer) && !limit.negative?
  end

  def truncation(result, records, offset)
    read = Lighthouse::GraphQL::Pagination.covered(records)
    window = ", and no further than its first #{result.result_window} matches (the index.max_result_window)" if result.result_window
    "@all answered #{read} of the #{result.count - offset} matches the search finds from offset #{offset}: a search reads " \
      "#{Lighthouse::Search::Result::READ_LIMIT} at most at once#{window}. Use @paginate, or `first` and `offset`, to read the others."
  end

  def extract_model_name
    arg = @directive_node.arguments&.find { |a| a.name == 'model' }
    return nil unless arg

    arg.value.respond_to?(:value) ? arg.value.value : arg.value
  end
end
