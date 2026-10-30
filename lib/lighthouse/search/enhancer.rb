# frozen_string_literal: true

# Runs a field's search when the client sent one, as PHP Lighthouse's
# ScoutEnhancer does: an argument carrying @search with a string value (`""`
# included; null or omitted falls back to the database query). BaseDirectiveResolver
# calls it before the argument builders.
#
# - With a relational adapter (pg_search) it narrows the relation, and every
#   other directive of the field applies on top as usual.
# - Otherwise (Searchkick) the directives of the other arguments the client sent
#   write to a Search::Query (Contracts::SearchBuilder), and the answer is a
#   Search::Result instead of a relation. Any other argument directive the client
#   sends is an error, as is a second @search.
class Lighthouse::Search::Enhancer
  # An argument directive of the field: its AST nodes, the builder class (or :builder), the client's value.
  Argument = Struct.new(:node, :directive, :builder, :value, :present)

  def initialize(arguments, relation, results:, context:)
    @arguments = arguments
    @relation = relation
    @results = results
    @context = context
  end

  # The relation, searched; or a Search::Result. The relation itself if the client sent no search.
  def enhance
    search = the_search
    return @relation unless search

    model = @relation.klass
    index = Lighthouse::Support::DirectiveArgs.literal(search.directive, 'within')
    adapter = Lighthouse::Search.adapter_for(model, index) ||
              raise(Lighthouse::DefinitionError, "@search: #{model.name} is not searchable (#{Lighthouse::Search::FieldCheck::HINT}).")
    query = Lighthouse::Search::Query.new(model, search.value, index)
    return adapter.scope(@relation, query) if adapter.relational?

    result(adapter, query)
  end

  private

  def the_search
    searches = @arguments.select { |argument| search?(argument) && argument.value.is_a?(String) }
    raise ::GraphQL::ExecutionError, 'Found more than 1 argument with @search.' if searches.size > 1

    searches.first
  end

  def search?(argument)
    argument.builder == Lighthouse::GraphQL::Directives::Arguments::Search
  end

  def result(adapter, query)
    unless @results
      raise Lighthouse::DefinitionError,
            "@search with #{adapter.class.name.demodulize} answers outside the database: only @all and @paginate on a root field can use it."
    end

    reject_incompatible
    query = @arguments.reject { |argument| search?(argument) }.reduce(query) { |narrowed, argument| narrow(narrowed, argument) }
    Lighthouse::Search::Result.new(adapter, query)
  end

  # The directives of an argument the client sent that a search engine cannot apply.
  def reject_incompatible
    incompatible = @arguments.find do |argument|
      !search?(argument) && !argument.value.nil? && !compatible?(argument.builder)
    end
    return unless incompatible

    raise ::GraphQL::ExecutionError,
          "Found arg builder arguments that do not work with @search: @#{incompatible.directive.name} on #{incompatible.node.name}."
  end

  def compatible?(builder)
    builder == :builder || builder.include?(Lighthouse::Contracts::SearchBuilder)
  end

  def narrow(query, argument)
    if argument.builder == :builder
      return query unless argument.present

      Lighthouse::GraphQL::DirectiveResolvers::BuilderApplier.apply_argument(query, argument.directive, argument.value, @context)
    elsif argument.value.nil?
      query
    else
      argument.builder.new(argument.node, argument.directive).handle_search_builder(query, argument.value)
    end
  end
end
