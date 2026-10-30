# frozen_string_literal: true

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
# - in a subscription, they are disabled with `if: false` (or a variable);
# - @stream is on a list field.
#
# A document without either directive is not walked (`analyze?`).
class Lighthouse::GraphQL::Incremental::Rules < GraphQL::Analysis::Analyzer
  def initialize(subject)
    super
    @errors = []
    @seen = {}.compare_by_identity
  end

  def analyze?
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

  # The node's directive `name`, once checked; nil without one, or once it was (a fragment
  # spread twice is visited twice). `parent_type`: the type of the selection set the node is in.
  def check(node, name, parent_type)
    directive = node.directives.find { |candidate| candidate.name == name }
    return nil if directive.nil? || @seen.key?(directive)

    @seen[directive] = true
    error(directive, "The @#{name} directive cannot be used on a root mutation field.") if mutation_root?(parent_type)
    check_subscription(directive)
    directive
  end

  def mutation_root?(type)
    !type.nil? && type == query.schema.root_type_for_operation('mutation')
  end

  def check_subscription(directive)
    return unless query.selected_operation.operation_type == 'subscription'

    disabled = directive.arguments.find { |argument| argument.name == 'if' }&.value
    return if disabled == false || disabled.is_a?(::GraphQL::Language::Nodes::VariableIdentifier)

    error(directive, "The @#{directive.name} directive must be disabled with `if: false` in a subscription.")
  end

  # The errors of the labels of the whole document, in its order.
  def labels
    seen = {}
    directives(query.document.definitions).filter_map do |directive|
      label = directive.arguments.find { |argument| argument.name == 'label' }&.value
      next if label.nil?
      next failure(directive, "The label of @#{directive.name} must be a String literal, not a variable.") unless label.is_a?(String)
      next failure(directive, "The label \"#{label}\" is used by more than one @defer or @stream in the document.") if seen.key?(label)

      seen[label] = true
      nil
    end
  end

  # Every @defer and @stream of the nodes, each fragment definition once (it is a definition).
  def directives(nodes)
    nodes.flat_map do |node|
      own = if node.respond_to?(:directives)
              node.directives.select do |directive|
                Lighthouse::GraphQL::Incremental::Document::DIRECTIVES.include?(directive.name)
              end
            else
              []
            end
      own + (node.respond_to?(:selections) ? directives(node.selections) : [])
    end
  end

  def error(node, message)
    @errors << failure(node, message)
  end

  def failure(node, message) = ::GraphQL::AnalysisError.new(message, ast_node: node)
end
