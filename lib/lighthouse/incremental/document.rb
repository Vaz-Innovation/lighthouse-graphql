# frozen_string_literal: true

require 'set'

# Reads a query's @defer and @stream for Run: stamps each with the number of its
# fragment (as its `label`, see DeferDirective) in a copy of the document, with
# the fragments it found. The rules the directives follow are Rules', which
# graphql-ruby checks for every query, before the first pass runs.
#
# A field is deferred only when every declaration of it is, as Apollo and PHP
# Lighthouse have it: a field of a deferred fragment that the selection set also
# asks for outside any @defer (itself, or through a fragment without directives)
# comes in the payload that delivers the other declaration, and does not resolve
# again. A leaf (`id` in `{ id ... @defer { id name } }`) is left out of the
# fragment; a field with selections moves, with them, to an inline fragment next
# to it that is not deferred (with the fragment's type condition, @skip and
# @include), so graphql-ruby merges it into the other declaration. A fragment
# left with nothing of its own is not deferred at all. Only the fragment's own
# fields are looked at, not those of the fragments it holds.
class Lighthouse::GraphQL::Incremental::Document
  Nodes = ::GraphQL::Language::Nodes
  DIRECTIVES = %w[defer stream].freeze
  Prepared = Struct.new(:document, :fragments, keyword_init: true)

  # Where a selection set sits: the type it selects on, and the response keys it asks for
  # outside any @defer (its own, and an enclosing one's on the same object).
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
    scope = Scope.new(@schema.root_type_for_operation(definition.operation_type), Set.new)
    definition.merge(selections: walk(definition.selections, scope))
  end

  # A fragment definition, stamped. A cycle (invalid, and reported later by graphql-ruby) is left as it is.
  def stamped_definition(name)
    return @stamped[name] if @stamped.key?(name)

    definition = @definitions[name] or return nil
    @stamped[name] = definition
    scope = Scope.new(@schema.get_type(definition.type.name), Set.new)
    @stamped[name] = definition.merge(selections: walk(definition.selections, scope))
  end

  # `scope.covered`: what an enclosing selection set on the same object asks for.
  def walk(selections, scope)
    scope = Scope.new(scope.type, scope.covered | covered(selections, scope.type))

    selections.flat_map do |selection|
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
    selections = walk(selections, Scope.new(definition&.type&.unwrap, Set.new)) unless selections.empty?
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
    inner = walk(node.selections, Scope.new(condition ? @schema.get_type(condition) : scope.type, scope.covered))
    stamp(node, inner, scope, condition) { |selections| node.merge(selections: selections) }
  end

  def fragment_spread(node, scope)
    definition = stamped_definition(node.name)
    return node unless definition

    stamp(node, definition.selections, scope, definition.type.name) { |_| node }
  end

  # `node` with its @defer stamped (and, next to it, what it brings to the first payload);
  # `selections` are what a deferred fragment runs, `condition` the name of its type condition.
  def stamp(node, selections, scope, condition)
    defer = node.directives.find { |directive| directive.name == 'defer' }
    return yield(selections).merge(directives: node.directives) unless stampable?(defer)

    others = node.directives.reject { |directive| directive.equal?(defer) }
    shared, kept = selections.partition { |selection| shared?(selection, scope) }
    return yield(selections).merge(directives: others) if kept.empty?

    id = register(defer, kept, scope, condition)
    # @skip and @include answer before @defer does.
    [yield(selections).merge(directives: others + [stamp_label(defer, id)]), *brought(shared, condition, others)]
  end

  # A deferred fragment that runs `selections`: its number.
  def register(defer, selections, scope, condition)
    @fragments << Lighthouse::GraphQL::Incremental::State::Fragment.new(
      id: @fragments.size, node: Nodes::InlineFragment.new(selections: selections),
      condition: condition, parent_type: scope.type&.graphql_name, label: label_of(defer)
    )
    @fragments.size - 1
  end

  # The fields with selections a deferred fragment shares with the rest, in an inline fragment that is not deferred.
  def brought(shared, condition, directives)
    shared = shared.reject { |field| field.selections.empty? }
    return [] if shared.empty?

    [Nodes::InlineFragment.new(type: condition && Nodes::TypeName.new(name: condition), directives: directives, selections: shared)]
  end

  # The response keys `selections` ask for wherever they run on an object of `type`, outside any
  # @defer: their fields without directives, and those of their fragments without directives that
  # apply to every object of the type.
  def covered(selections, type, seen = Set.new)
    selections.each_with_object(Set.new) do |selection, keys|
      next unless selection.directives.empty?

      selection.is_a?(Nodes::Field) ? keys << response_key(selection) : keys.merge(fragment_keys(selection, type, seen))
    end
  end

  # Those of an inline fragment or a fragment spread (each definition once).
  def fragment_keys(fragment, type, seen)
    if fragment.is_a?(Nodes::FragmentSpread)
      definition = @definitions[fragment.name]
      return [] unless definition && seen.add?(fragment.name)

      fragment = definition
    end
    applies?(fragment.type&.name, type) ? covered(fragment.selections, type, seen) : []
  end

  # Does a type condition hold for every object of `type`?
  def applies?(condition, type)
    return true if condition.nil? || condition == type&.graphql_name
    return false unless type&.kind&.object?

    named = @schema.get_type(condition)
    !named.nil? && @schema.possible_types(named).include?(type)
  end

  def response_key(field) = field.alias || field.name

  # A field the selection set asks for outside any @defer.
  def shared?(selection, scope)
    selection.is_a?(Nodes::Field) && scope.covered.include?(response_key(selection))
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

  def label_of(directive)
    argument = directive.arguments.find { |arg| arg.name == 'label' }
    argument&.value.is_a?(String) ? argument.value : nil
  end
end
