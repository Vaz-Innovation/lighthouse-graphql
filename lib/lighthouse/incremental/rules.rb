# frozen_string_literal: true

require 'set'

# The rules @defer and @stream follow, checked for every query of a schema that
# uses Defer however it runs: streamed, answered whole to a JSON client, through
# `schema.execute`, in a batch. A graphql-ruby query analyzer (Defer.use installs
# it), so a query that breaks them gets the errors and no data, as a validation
# error would. The analyzer sees the selected operation with its fragment spreads
# inlined: a named fragment is checked where it is spread, under the operation and
# the type it runs on.
#
# From the specification draft (section 5.7), with PHP Lighthouse's message where it has one:
#
# - `label` is a String literal, not a variable, and no two directives of the
#   document share it (every operation and fragment of it, as a validation rule
#   would see them, not only those of the operation that runs);
# - @defer and @stream are not used on a root mutation field, whose fields must run
#   one after the other ("The @defer directive cannot be used on a root mutation
#   field.", as PHP Lighthouse words it), whether the fragment is inline or named;
# - in a subscription, they are disabled with `if: false`, or a variable that is false;
# - @stream is on a list field.
#
# A query whose text names neither directive, or whose document (given as one) has
# neither, is not walked (`analyze?`). A named fragment spread at several places is
# checked at each, and an error reported once a directive.
class Lighthouse::GraphQL::Incremental::Rules < GraphQL::Analysis::Analyzer
  def initialize(subject)
    super
    @errors = []
    @reported = Set.new
    @definitions = Lighthouse::GraphQL::Incremental::Document::Definitions.new(subject.schema)
  end

  # The text the query was given (graphql-ruby's Query#query_string would print a document given
  # instead): the names defer and stream in it first, the document's walk only where it has one.
  def analyze?
    text = query.instance_variable_get(:@query_string)
    return false if text.is_a?(String) && !Lighthouse::GraphQL::Incremental::Document::INCREMENTAL.match?(text)

    Lighthouse::GraphQL::Incremental::Document.incremental?(query.document)
  end

  # The fragment's type is on the visitor's stack already: the selection set's is the one below it.
  def on_enter_inline_fragment(node, _parent, visitor)
    check(node, 'defer', visitor.parent_type_definition)
  end

  # Called before the visitor enters the fragment's type.
  def on_enter_fragment_spread(node, _parent, visitor)
    check(node, 'defer', visitor.type_definition)
  end

  def on_enter_field(node, _parent, visitor)
    stream = check(node, 'stream', visitor.parent_type_definition) or return
    field = visitor.field_definition
    error(stream, 'The @stream directive must be used on a list field.') if field && !field.type.list?
  end

  def result = labels + @errors

  private

  # The node's directive `name`, checked where it is; nil without one. `parent_type`: the type of
  # the selection set the node is in.
  def check(node, name, parent_type)
    directive = node.directives.find { |candidate| candidate.name == name } or return nil
    error(directive, "The @#{name} directive cannot be used on a root mutation field.") if mutation_root?(parent_type)
    check_subscription(directive)
    directive
  end

  def mutation_root?(type)
    !type.nil? && type == query.schema.root_type_for_operation('mutation')
  end

  # A subscription's directive is disabled: `if: false`, or a variable that is false here (the draft
  # allows a variable, and forbids incremental delivery in a subscription, so a true one is refused).
  def check_subscription(directive)
    return unless query.selected_operation.operation_type == 'subscription'
    return if query.arguments_for(directive, @definitions[directive.name])[:if] == false

    error(directive, "The @#{directive.name} directive must be disabled with `if: false` in a subscription.")
  end

  # The errors of the labels of the whole document, in its order.
  def labels
    seen = {}
    directives(query.document.definitions).filter_map do |directive|
      label = directive.arguments.find { |argument| argument.name == 'label' }&.value
      variable = label.is_a?(::GraphQL::Language::Nodes::VariableIdentifier)
      next failure(directive, "The label of @#{directive.name} must be a String literal, not a variable.") if variable
      next unless label.is_a?(String) # none, or null: no label
      next failure(directive, "The label \"#{label}\" is used by more than one @defer or @stream in the document.") if seen.key?(label)

      seen[label] = true
      nil
    end
  end

  # Every @defer and @stream of the definitions, each fragment definition once (it is one).
  def directives(definitions)
    [].tap do |found|
      definitions.select { |definition| definition.respond_to?(:selections) }.each do |definition|
        Lighthouse::GraphQL::Incremental::Document.visit_directives(definition.selections) { |directive, _| found << directive }
      end
    end
  end

  # An error, once for a node.
  def error(node, message)
    @errors << failure(node, message) if @reported.add?([node.object_id, message])
  end

  def failure(node, message) = ::GraphQL::AnalysisError.new(message, ast_node: node)
end
