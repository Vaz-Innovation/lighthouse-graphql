# frozen_string_literal: true

# Reads a query's @defer for Run: checks the rules the specification draft sets
# for the directive (section 5), and stamps each @defer with the number of its
# fragment (as its `label`, see DeferDirective) in a copy of the document, with
# the fragments it found.
#
# The rules, which hold whether or not the response is streamed:
#
# - `label` is a String literal, not a variable, and no two @defer share it;
# - @defer does not sit at the root of a mutation, whose fields must run one
#   after the other, and a subscription's is disabled with `if: false` (or a variable).
#
# A fragment leaves out the fields its selection set already asks for outside
# it (`id` in `{ id ... @defer { id name } }`), which the first response delivers:
# only those without selections or directives of their own, so no field resolves twice.
class Lighthouse::GraphQL::Incremental::Document
  Nodes = ::GraphQL::Language::Nodes
  DIRECTIVES = %w[defer stream].freeze
  Prepared = Struct.new(:document, :fragments, :errors, keyword_init: true)

  # Where a selection set sits: the operation type (nil under a fragment definition),
  # whether it is the operation's own selection set and not a field's (`root`), the
  # type it selects on, and the response keys of the fields it asks for itself.
  Scope = Struct.new(:kind, :root, :type, :covered)

  def self.prepare(schema, document)
    new(schema, document).prepare
  end

  def initialize(schema, document)
    @schema = schema
    @document = document
    @fragments = []
    @errors = []
    @labels = {}
    @definitions = document.definitions.grep(Nodes::FragmentDefinition).index_by(&:name)
    @stamped = {}
  end

  def prepare
    definitions = @document.definitions.map do |definition|
      case definition
      when Nodes::OperationDefinition then operation(definition)
      when Nodes::FragmentDefinition then stamped_definition(definition.name)
      else definition
      end
    end
    Prepared.new(document: @document.merge(definitions: definitions), fragments: @fragments, errors: @errors)
  end

  private

  def operation(definition)
    scope = Scope.new(definition.operation_type, true, @schema.root_type_for_operation(definition.operation_type))
    definition.merge(selections: walk(definition.selections, scope))
  end

  # A fragment definition, stamped. A cycle (invalid, and reported later by graphql-ruby) is left as it is.
  def stamped_definition(name)
    return @stamped[name] if @stamped.key?(name)

    definition = @definitions[name] or return nil
    @stamped[name] = definition
    scope = Scope.new(nil, false, @schema.get_type(definition.type.name))
    @stamped[name] = definition.merge(selections: walk(definition.selections, scope))
  end

  def walk(selections, scope)
    scope = scope.dup
    scope.covered = selections.grep(Nodes::Field).select { |field| field.directives.empty? }.to_set { |field| field.alias || field.name }

    selections.map do |selection|
      case selection
      when Nodes::Field then field(selection, scope)
      when Nodes::InlineFragment then inline_fragment(selection, scope)
      when Nodes::FragmentSpread then fragment_spread(selection, scope)
      else selection
      end
    end
  end

  def field(node, scope)
    type = scope.type
    definition = type && !type.kind.union? ? @schema.get_field(type, node.name) : nil
    selections = node.selections
    selections = walk(selections, Scope.new(scope.kind, false, definition&.type&.unwrap)) unless selections.empty?
    node.merge(selections: selections, directives: check_directives(node, scope))
  end

  def inline_fragment(node, scope)
    condition = node.type&.name
    inner = walk(node.selections, Scope.new(scope.kind, scope.root, condition ? @schema.get_type(condition) : scope.type))
    stamp(node, inner, scope, condition) { |selections| node.merge(selections: selections) }
  end

  def fragment_spread(node, scope)
    definition = stamped_definition(node.name)
    return node.merge(directives: check_directives(node, scope)) unless definition

    stamp(node, definition.selections, scope, definition.type.name) { |_| node }
  end

  # `node` with its @defer stamped, once the directives are checked; `selections`
  # are what a deferred fragment runs, `condition` the name of its type condition.
  def stamp(node, selections, scope, condition)
    directives = check_directives(node, scope)
    defer = directives.find { |directive| directive.name == 'defer' }
    return yield(selections).merge(directives: directives) unless defer

    id = @fragments.size
    @fragments << Lighthouse::GraphQL::Incremental::State::Fragment.new(
      id: id, node: Nodes::InlineFragment.new(selections: prune(selections, scope.covered)),
      condition: condition, parent_type: scope.type&.graphql_name, label: label_of(defer)
    )
    # @skip and @include answer before @defer does.
    yield(selections).merge(directives: directives.reject { |directive| directive.equal?(defer) } + [stamp_label(defer, id)])
  end

  # The directive with the fragment's number as its label.
  def stamp_label(directive, id)
    label = Nodes::Argument.new(name: 'label', value: "#{Lighthouse::GraphQL::Incremental::State::STAMP}#{id}")
    directive.merge(arguments: directive.arguments.reject { |argument| argument.name == 'label' } + [label])
  end

  # The fragment's fields, but those the rest of the selection set delivers.
  def prune(selections, covered)
    return selections if covered.empty?

    selections.reject do |selection|
      selection.is_a?(Nodes::Field) && selection.selections.empty? && selection.directives.empty? &&
        covered.include?(selection.alias || selection.name)
    end
  end

  def label_of(directive)
    argument = directive.arguments.find { |arg| arg.name == 'label' }
    argument&.value.is_a?(String) ? argument.value : nil
  end

  # Reports what breaks the rules; the directives come back as they were.
  def check_directives(node, scope)
    node.directives.each do |directive|
      next unless DIRECTIVES.include?(directive.name)

      check_label(directive)
      error(directive, "The @#{directive.name} directive cannot be used on a root field of a mutation.") if scope.kind == 'mutation' && scope.root
      check_subscription(directive, scope.kind)
    end
    node.directives
  end

  def check_subscription(directive, kind)
    return unless kind == 'subscription'

    disabled = directive.arguments.find { |argument| argument.name == 'if' }&.value
    return if disabled == false || disabled.is_a?(Nodes::VariableIdentifier)

    error(directive, "The @#{directive.name} directive must be disabled with `if: false` in a subscription.")
  end

  def check_label(directive)
    argument = directive.arguments.find { |arg| arg.name == 'label' } or return
    unless argument.value.is_a?(String)
      error(directive, "The label of @#{directive.name} must be a String literal, not a variable.")
      return
    end

    if @labels.key?(argument.value)
      error(directive, "The label \"#{argument.value}\" is used by more than one @defer or @stream in the document.")
    else
      @labels[argument.value] = true
    end
  end

  def error(node, message)
    @errors << ::GraphQL::StaticValidation::Error.new(message, nodes: [node])
  end
end
