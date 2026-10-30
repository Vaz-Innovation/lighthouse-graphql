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

  # Can a search engine take the argument directive (its builder class, or :builder,
  # and its node)? It applies one that writes to the search (Contracts::SearchBuilder,
  # @builder), and leaves alone one that does not change the query (`changes_query?`:
  # @limit without `builder: true`). Search::FieldCheck asks too, of the defaults.
  def self.compatible?(builder, directive)
    builder == :builder || builder.include?(Lighthouse::Contracts::SearchBuilder) ||
      (builder.respond_to?(:changes_query?) && !builder.changes_query?(directive))
  end

  # `search`: what the caller takes from an engine (BaseDirectiveResolver::SEARCHES):
  # nil, a relation only; :model, a Search::Result for the model's own relation it
  # built (with the `scopes:` Search::FieldCheck refuses for an engine), searched
  # whole without a check; :given, one for a relation the app's code gave, checked.
  # `field`: "Type.field", for the client's errors.
  def initialize(arguments, relation, search:, context:, field: 'the field')
    @arguments = arguments
    @relation = relation
    @search = search
    @context = context
    @field = field
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
    unless @search
      raise ::GraphQL::ExecutionError,
            "@search with #{adapter.class.name.demodulize} answers outside the database, and #{@field} pages a relation here: it cannot search it."
    end

    whole_index!(adapter) if @search == :given
    reject_incompatible
    query = @arguments.reject { |argument| search?(argument) }.reduce(query) { |narrowed, argument| narrow(narrowed, argument) }
    Lighthouse::Search::Result.new(adapter, query)
  end

  # The engine searches the model's whole index: the conditions of a relation
  # narrowed beforehand (`resolve_info.enhance_builder(Post.where(...))`) would be
  # lost, and the search could find records the relation leaves out. A relation
  # the app's code gives (enhance_builder) must select what the model's own does.
  def whole_index!(adapter)
    model = @relation.klass
    return if unnarrowed?(@relation, model.all)

    raise Lighthouse::DefinitionError,
          "@search with #{adapter.class.name.demodulize} searches the whole index of #{model.name}: it cannot apply the conditions " \
          "of the relation it was given. Search #{model.name}.all, and narrow the search with the field's arguments."
  end

  # The parts of a relation that decide which records it selects.
  SELECTING = %i[where_clause having_clause from_clause joins_values left_outer_joins_values group_values limit_value offset_value].freeze

  # Does the relation select what the model's own does? Each part equals the
  # model's, conditions and their values included; anything else is refused, a
  # default scope whose values read the clock too, since it cannot be told apart.
  def unnarrowed?(relation, base)
    !null_relation?(relation) && SELECTING.all? { |part| relation.public_send(part) == base.public_send(part) }
  end

  # `none`: a null relation (Rails 7.1+ answers null_relation?).
  def null_relation?(relation)
    return relation.null_relation? if relation.respond_to?(:null_relation?)

    defined?(::ActiveRecord::NullRelation) && relation.is_a?(::ActiveRecord::NullRelation)
  end

  # The directives of an argument the client sent that a search engine cannot apply.
  def reject_incompatible
    incompatible = @arguments.find do |argument|
      !search?(argument) && !argument.value.nil? && !self.class.compatible?(argument.builder, argument.directive)
    end
    return unless incompatible

    raise ::GraphQL::ExecutionError,
          "Found arg builder arguments that do not work with @search: @#{incompatible.directive.name} on #{incompatible.node.name}."
  end

  def narrow(query, argument)
    if argument.builder == :builder
      return query unless argument.present

      Lighthouse::GraphQL::DirectiveResolvers::BuilderApplier.apply_argument(query, argument.directive, argument.value, @context, strict: true)
    elsif !argument.value.nil? && argument.builder.include?(Lighthouse::Contracts::SearchBuilder)
      argument.builder.new(argument.node, argument.directive).handle_search_builder(query, argument.value)
    else
      query # nothing sent, or a directive that leaves the query alone
    end
  end
end
