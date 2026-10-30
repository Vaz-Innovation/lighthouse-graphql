# frozen_string_literal: true

require 'set'

# What incremental delivery reads of the client's document, which it never
# rewrites: graphql-ruby runs the document as the client sent it, and listeners,
# `query_string`, tracing and Rules all see that one.
#
# - `directives(name)`: the @defer and @stream directive nodes the operation reaches,
#   and `owner(directive)`, the fragment or field each sits on. State tells them apart
#   at run time by node identity (see State#directive_for).
# - `selections(fragment)`, `condition(fragment)`: what a deferred fragment selects.
# - `declarations(pattern)`: every declaration of the field at a response path, with what
#   decides whether it is part of the field's selection set for a given object. A
#   streamed field's later items get the selections of all of them (Document#merged),
#   as graphql-ruby merges them for the first ones.
# - `included?`, `applies?`, `deferred?`: a node's @skip/@include, a fragment's type
#   condition and a fragment's @defer, evaluated with a query's variables.
class Lighthouse::GraphQL::Incremental::Document
  Nodes = ::GraphQL::Language::Nodes
  DIRECTIVES = %w[defer stream].freeze

  # A declaration of a field: the field node, the fragments around it in its parent's
  # selection set (`around`, whose type conditions are the parent object's), the fragments and
  # fields above those (`gates`, whose @skip and @include must hold), whether one of those has
  # a type condition only some objects meet (`uncertain`: it cannot be told from the parent
  # object), and the @defer fragments around it, at any level.
  Declaration = Struct.new(:field, :around, :gates, :uncertain, :defers, keyword_init: true)

  # Where the walk of `declarations` is: the response path (without list indices), the type of
  # the selection set the level starts with and the one it is in, and what a Declaration holds.
  At = Struct.new(:pattern, :level_type, :type, :around, :gates, :uncertain, :defers, keyword_init: true)

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

  attr_reader :schema

  # `operation`: the operation that runs (GraphQL::Query#selected_operation).
  def initialize(schema, document, operation)
    @schema = schema
    @operation = operation
    @definitions = document.definitions.grep(Nodes::FragmentDefinition).index_by(&:name)
    @owners = {}.compare_by_identity
  end

  def directives(name)
    (@directives ||= collect_directives)[name] || []
  end

  def owner(directive)
    directives('defer')
    @owners[directive]
  end

  def selections(fragment)
    fragment.is_a?(Nodes::FragmentSpread) ? @definitions[fragment.name]&.selections.to_a : fragment.selections
  end

  def condition(fragment)
    (fragment.is_a?(Nodes::FragmentSpread) ? @definitions[fragment.name]&.type : fragment.type)&.name
  end

  def declarations(pattern)
    (@index ||= index)[pattern] || []
  end

  # Do the node's @skip and @include let it through?
  def included?(node, query)
    node.directives.all? do |directive|
      case directive.name
      when 'skip' then !argument(directive, query)
      when 'include' then argument(directive, query)
      else true
      end
    end
  end

  # Does the fragment's type condition hold for an object of the object type `type`?
  def applies?(fragment, type, query)
    name = condition(fragment) or return true
    named = query.types.type(name)
    !named.nil? && query.types.possible_types(named).include?(type)
  end

  # Does the fragment carry a @defer that `if` does not turn off?
  def deferred?(fragment, query)
    directive = fragment.directives.find { |candidate| candidate.name == 'defer' } or return false
    argument(directive, query) != false
  end

  # The selections the later items of a streamed list run: those of each declaration of the field
  # at `path` that holds for the parent object (of type `parent_type`). nil when that cannot be
  # told (a declaration under a type condition of an object above the parent, or under another
  # @defer that `deferring` would defer): the list is then answered whole.
  def merged(directive, path, parent_type, query, deferring)
    field = owner(directive)
    declarations = declarations(path.grep_v(Integer))
    own = declarations.find { |declaration| declaration.field.equal?(field) } or return nil
    declarations.each_with_object(field.selections.dup) do |declaration, selections|
      next if declaration.equal?(own)
      return nil if unknowable?(declaration, own, query, deferring)

      selections.concat(declaration.field.selections) if holds?(declaration, parent_type, query)
    end
  end

  private

  def argument(directive, query)
    query.arguments_for(directive, @schema.directives[directive.name])[:if]
  end

  def holds?(declaration, parent_type, query)
    (declaration.gates + declaration.around + [declaration.field]).all? { |node| included?(node, query) } &&
      declaration.around.all? { |fragment| applies?(fragment, parent_type, query) }
  end

  # Whether a declaration is part of the field's selection set cannot be told from the parent
  # object: a type condition above it, or a @defer around it but not around `own` that defers.
  def unknowable?(declaration, own, query, deferring)
    declaration.uncertain || (deferring && (declaration.defers - own.defers).any? { |fragment| deferred?(fragment, query) })
  end

  # The directive nodes the operation reaches, each fragment definition walked once.
  def collect_directives
    Hash.new { |hash, name| hash[name] = [] }.tap { |found| gather(@operation&.selections.to_a, found, Set.new) }
  end

  def gather(selections, found, seen)
    selections.each do |selection|
      selection.directives.each do |directive|
        next unless DIRECTIVES.include?(directive.name)

        found[directive.name] << directive
        @owners[directive] = selection
      end
      next gather(selection.selections, found, seen) unless selection.is_a?(Nodes::FragmentSpread)

      gather(@definitions[selection.name].selections, found, seen) if @definitions.key?(selection.name) && seen.add?(selection.name)
    end
  end

  def index
    {}.tap do |index|
      root = @schema.root_type_for_operation(@operation.operation_type)
      top = At.new(pattern: [], level_type: root, type: root, around: [], gates: [], uncertain: false, defers: [])
      collect(@operation.selections, top, index, [])
    end
  end

  def collect(selections, at, index, stack)
    selections.each do |selection|
      case selection
      when Nodes::Field then declare(selection, at, index, stack)
      when Nodes::InlineFragment then within(selection, selection.selections, at, index, stack)
      when Nodes::FragmentSpread
        definition = @definitions[selection.name]
        within(selection, definition.selections, at, index, stack + [selection.name]) if definition && stack.exclude?(selection.name)
      end
    end
  end

  def declare(field, at, index, stack)
    pattern = at.pattern + [field.alias || field.name]
    (index[pattern] ||= []) << Declaration.new(field: field, around: at.around, gates: at.gates, uncertain: at.uncertain, defers: at.defers)
    collect(field.selections, below(field, at, pattern), index, stack) unless field.selections.empty?
  end

  # Where the walk is in the field's selection set.
  def below(field, at, pattern)
    type = field_type(at.type, field)
    uncertain = at.uncertain || at.around.any? { |fragment| !always?(condition(fragment), at.level_type) }
    At.new(pattern: pattern, level_type: type, type: type, around: [], gates: at.gates + at.around + [field], uncertain: uncertain, defers: at.defers)
  end

  def field_type(type, field)
    return nil if type.nil? || type.kind.union?

    @schema.get_field(type, field.name)&.type&.unwrap
  end

  def within(fragment, selections, at, index, stack)
    name = condition(fragment)
    defers = fragment.directives.any? { |directive| directive.name == 'defer' } ? at.defers + [fragment] : at.defers
    collect(selections, at.dup.tap do |inner|
      inner.type = name ? @schema.get_type(name) : at.type
      inner.around = at.around + [fragment]
      inner.defers = defers
    end, index, stack)
  end

  # Does a type condition hold for every object of `type`?
  def always?(name, type)
    return true if name.nil? || name == type&.graphql_name
    return false unless type&.kind&.object?

    named = @schema.get_type(name)
    !named.nil? && @schema.possible_types(named).include?(type)
  end
end
