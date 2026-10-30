# frozen_string_literal: true

# Reads a query's @defer and @stream for Run: stamps each with the number of its
# fragment (as its `label`, see DeferDirective) in a copy of the document, with
# the fragments it found. The rules the directives follow are Rules', which
# graphql-ruby checks for every query, before the first pass runs.
#
# A fragment leaves out the fields its selection set already asks for outside
# it (`id` in `{ id ... @defer { id name } }`), which the first response delivers:
# only those without selections or directives of their own, so no field resolves twice.
class Lighthouse::GraphQL::Incremental::Document
  Nodes = ::GraphQL::Language::Nodes
  DIRECTIVES = %w[defer stream].freeze
  Prepared = Struct.new(:document, :fragments, keyword_init: true)

  # Where a selection set sits: the type it selects on, and the response keys of the fields it asks for itself.
  Scope = Struct.new(:type, :covered)

  def self.prepare(schema, document)
    new(schema, document).prepare
  end

  # Does the document use @defer or @stream? A walk of its selections, for the queries that do not.
  def self.incremental?(document)
    document.definitions.any? { |definition| definition.respond_to?(:selections) && uses?(definition.selections) }
  end

  def self.uses?(selections)
    selections.any? do |selection|
      selection.directives.any? { |directive| DIRECTIVES.include?(directive.name) } ||
        (selection.respond_to?(:selections) && uses?(selection.selections))
    end
  end

  def initialize(schema, document)
    @schema = schema
    @document = document
    @fragments = []
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
    Prepared.new(document: @document.merge(definitions: definitions), fragments: @fragments)
  end

  private

  def operation(definition)
    scope = Scope.new(@schema.root_type_for_operation(definition.operation_type))
    definition.merge(selections: walk(definition.selections, scope))
  end

  # A fragment definition, stamped. A cycle (invalid, and reported later by graphql-ruby) is left as it is.
  def stamped_definition(name)
    return @stamped[name] if @stamped.key?(name)

    definition = @definitions[name] or return nil
    @stamped[name] = definition
    scope = Scope.new(@schema.get_type(definition.type.name))
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
    selections = walk(selections, Scope.new(definition&.type&.unwrap)) unless selections.empty?
    node.merge(selections: selections, directives: stamp_stream(node.directives))
  end

  # The field's @stream, if it has one, stamped.
  def stamp_stream(directives)
    stream = directives.find { |directive| directive.name == 'stream' }
    return directives unless stampable?(stream)

    id = @fragments.size
    @fragments << Lighthouse::GraphQL::Incremental::State::Fragment.new(id: id, label: label_of(stream), stream: true)
    directives.reject { |directive| directive.equal?(stream) } + [stamp_label(stream, id)]
  end

  def inline_fragment(node, scope)
    condition = node.type&.name
    inner = walk(node.selections, Scope.new(condition ? @schema.get_type(condition) : scope.type))
    stamp(node, inner, scope, condition) { |selections| node.merge(selections: selections) }
  end

  def fragment_spread(node, scope)
    definition = stamped_definition(node.name)
    return node unless definition

    stamp(node, definition.selections, scope, definition.type.name) { |_| node }
  end

  # `node` with its @defer stamped; `selections` are what a deferred fragment runs,
  # `condition` the name of its type condition.
  def stamp(node, selections, scope, condition)
    directives = node.directives
    defer = directives.find { |directive| directive.name == 'defer' }
    return yield(selections).merge(directives: directives) unless stampable?(defer)

    id = @fragments.size
    @fragments << Lighthouse::GraphQL::Incremental::State::Fragment.new(
      id: id, node: Nodes::InlineFragment.new(selections: prune(selections, scope.covered)),
      condition: condition, parent_type: scope.type&.graphql_name, label: label_of(defer)
    )
    # @skip and @include answer before @defer does.
    yield(selections).merge(directives: directives.reject { |directive| directive.equal?(defer) } + [stamp_label(defer, id)])
  end

  # A directive Document can stamp: one with no label, or a literal one. A label that is a
  # variable (which Rules refuses) stays, or the variable would be unused.
  def stampable?(directive)
    !directive.nil? && !directive.arguments.find { |argument| argument.name == 'label' }&.value.is_a?(Nodes::VariableIdentifier)
  end

  # The directive with the fragment's number as its label, and the label the client gave after it.
  def stamp_label(directive, id)
    label = Nodes::Argument.new(name: 'label', value: Lighthouse::GraphQL::Incremental::State.stamp(id, label_of(directive)))
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
end
