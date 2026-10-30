# frozen_string_literal: true

# What a round of incremental delivery runs (Run#next_payload): the units of
# work of its pending fragments and lists, each a GraphQL::Query::Partial.
#
# As the specification draft has it, a deferred fragment's fields that the
# response already holds at its path (the rest of the query asked for them, or
# another fragment delivered them) are neither resolved nor sent again: each
# field resolves once. An object field the response already holds, to which a
# fragment adds selections, is not resolved again either: its object (kept by
# StreamTrace when it resolved) gets units of its own, sent at their `subPath`.
#
# The fields the fragments of a round select at a path make one unit per set of
# fragments that select them (the draft's grouped field sets): a field two of
# them select is sent once, for both, and fails both if it fails; a field only
# one of them selects is that one's, and fails it alone. The draft groups the
# fields below an object field the same way: when the fragments that select a
# field select different fields of its object, the field resolves on its own
# first (a pass), and those are planned on its object as if the response held
# it (`follow`), in the round's next pass.
#
# The deferred fragments nested in a unit's fragments, at the same path, are found
# here and pending for the next round, without a pass to find them.
class Lighthouse::GraphQL::Incremental::Plan
  Nodes = ::GraphQL::Language::Nodes
  State = Lighthouse::GraphQL::Incremental::State
  KNOWN = %w[skip include defer].freeze
  # What a field that resolves on its own selects of its object, left out of the data.
  PLACEHOLDER = '__lighthouse'
  PLACEHOLDER_NODE = Nodes::Field.new(name: '__typename', field_alias: PLACEHOLDER)

  # The object a fragment adds selections to was not kept (StreamTrace keeps every one a fragment
  # may need before it resolves): a bug, which fails the round.
  class Lost < StandardError; end

  # A Partial's work: `selections` on `object` (of `type`) at `path`, delivered for the pending
  # fragments that select them (`pendings`, `owner` the first), which complete with it, and the
  # fields it resolves on their own (`follow`). A stream's: its items `object`, at `positions`
  # of what the list left to stream (those that are null objects are left out: Delivery puts
  # them back).
  Unit = Struct.new(:owner, :pendings, :path, :object, :type, :selections, :positions, :follow, keyword_init: true) do
    def stream? = owner.stream?
  end

  # Where a unit runs: on `object`, of the object type `type`, at `path`.
  Spot = Struct.new(:path, :object, :type)

  # A field (at `key`, of the type `type`) a unit resolves on its own, and what each fragment
  # selects of it (`pairs`: each pending fragment with a node of the field).
  Follow = Struct.new(:key, :type, :pairs)

  # `tree`: the response's data so far, as the client has merged it.
  def initialize(query, state, tree)
    @query = query
    @state = state
    @document = state.document
    @schema = query.schema
    @tree = tree
  end

  # The units of the round's first pass.
  def units(pendings)
    streams, fragments = pendings.partition(&:stream?)
    units = gathered do
      fragments.group_by(&:path).each_value do |group|
        first = group.first
        plan(group.map { |pending| [pending, @document.selections(pending.node)] }, Spot.new(first.path, first.object, first.type))
      end
    end
    streams.map { |pending| stream(pending) } + units
  end

  # The units of the next pass: below the fields the units of the pass that ran (`units`, which
  # answered `responses`) resolved on their own. Their placeholders leave the data.
  def follow(units, responses)
    gathered do
      units.each_with_index do |unit, index|
        data = responses[index]['data'] or next
        unit.follow.to_a.each do |follow|
          value = strip(data[follow.key])
          path = unit.path + [follow.key]
          next if value.nil?

          targets(path, kept(path), value).each { |target, object| plan(by_pending(follow.pairs), spot(target, object, follow.type)) }
        end
      end
    end
  end

  private

  # A stream's unit: the items left to stream; graphql-ruby would run an object's fields on a
  # null item, so those that are null are not run.
  def stream(pending)
    items = pending.object.to_a
    positions = items.each_index.to_a
    positions.reject! { |index| items[index].nil? } unless pending.list_type.unwrap.kind.leaf?
    Unit.new(owner: pending, pendings: [pending], path: pending.path, object: items.values_at(*positions), type: pending.list_type,
             positions: positions)
  end

  # The units of what the block plans: by path, the fields each fragment selects there.
  def gathered
    @fields = {}
    yield
    @fields.values.flat_map do |spot, fields|
      fields.values.group_by { |pairs| pendings(pairs).map(&:object_id) }.map { |_, sets| unit(spot, sets) }
    end
  end

  # `entries`: each pending fragment, with the selections it has at `spot`.
  def plan(entries, spot)
    held = at(spot.path)
    held = nil unless held.is_a?(Hash)
    fields = (@fields[spot.path] ||= [spot, {}]).last
    shared = Hash.new { |hash, key| hash[key] = [] }
    entries.each do |pending, selections|
      flatten(selections, spot, pending).each { |selection| sort(selection, pending, held, fields, shared) }
    end
    shared.each { |key, pairs| descend(key, pairs, held[key], spot) unless held[key].nil? }
  end

  # A field the response holds goes to `shared` (when it adds selections to its object), with the
  # fragment it is of; any other selection to `fields`, by response key (a fragment kept as it is,
  # on its own).
  def sort(selection, pending, held, fields, shared)
    key = selection.is_a?(Nodes::Field) ? selection.alias || selection.name : selection
    return (fields[key] ||= []) << [pending, selection] unless held&.key?(key)

    shared[key] << [pending, selection] unless selection.selections.empty?
  end

  # The unit of the fields `sets` (one list of pairs a field) at `spot`, which the same fragments select.
  def unit(spot, sets)
    pendings = pendings(sets.first)
    follow = []
    selections = sets.flat_map do |pairs|
      next pairs.map(&:last).uniq(&:object_id) unless apart?(pairs)

      field = pairs.first.last
      follow << Follow.new(field.alias || field.name, @document.field_type(spot.type, field), pairs)
      pairs.map { |_, node| node.merge(selections: [PLACEHOLDER_NODE]) }
    end
    Unit.new(owner: pendings.first, pendings: pendings, path: spot.path, object: spot.object, type: spot.type, selections: selections,
             follow: follow)
  end

  # The fragments of `pairs`, in the order they were announced.
  def pendings(pairs) = pairs.map(&:first).uniq(&:object_id).sort_by { |pending| pending.id.to_i }

  # Do the fragments that select an object field select different fields of its object?
  def apart?(pairs)
    return false unless pairs.first.last.is_a?(Nodes::Field) && pairs.any? { |_, node| !node.selections.empty? }

    by_pending(pairs).map { |_, selections| selections.map(&:object_id) }.uniq.size > 1
  end

  # The fields `selections` select on the object, through the fragments that apply to it;
  # a fragment with a directive other than @skip, @include or @defer is kept as it is. A
  # deferred one is pending for the next round, under `pending`.
  def flatten(selections, spot, pending)
    selections.flat_map do |selection|
      next [] unless @document.included?(selection, @query)

      selection.is_a?(Nodes::Field) ? [selection] : fragment(selection, spot, pending)
    end
  end

  def fragment(fragment, spot, pending)
    return [] unless @document.applies?(fragment, spot.type, @query)
    return defer(fragment, spot, pending) if @state.deferring && @document.deferred?(fragment, @query)
    return [fragment] if fragment.directives.any? { |directive| KNOWN.exclude?(directive.name) }

    flatten(@document.selections(fragment), spot, pending)
  end

  def defer(fragment, spot, parent)
    directive = fragment.directives.find { |candidate| candidate.name == 'defer' }
    label = @query.arguments_for(directive, @document.directive('defer'))[:label]
    @state.found(self, State::Pending.new(node: fragment, object: spot.object, type: spot.type, path: spot.path, label: label,
                                          parents: [parent]))
    []
  end

  # The selections `pairs` (each pending fragment with a node of the field) add to the object (or
  # each object of the list) the response holds at `key`.
  def descend(key, pairs, held, spot)
    type = @document.field_type(spot.type, pairs.first.last) or return
    path = spot.path + [key]
    targets(path, kept(path), held).each { |target, object| plan(by_pending(pairs), spot(target, object, type)) }
  end

  # Each pending fragment of `pairs` with the selections of its nodes.
  def by_pending(pairs)
    pairs.group_by { |pending, _| pending.object_id }.map { |_, own| [own.first.first, own.flat_map { |_, node| node.selections }] }
  end

  # The object StreamTrace kept at `path`.
  def kept(path)
    value = @state.object_at(path)
    raise Lost, "Lighthouse kept no object at #{path.join('.')}" if value.equal?(State::MISSING)

    value
  end

  # The object at `path`, or those of the list there (the response holds `held`), each with its
  # path; none where the response holds null.
  def targets(path, value, held)
    return [[path, value]] unless held.is_a?(Array)

    objects = value.respond_to?(:to_a) ? value.to_a : []
    held.each_index.filter_map { |index| [path + [index], objects[index]] unless held[index].nil? || objects[index].nil? }
  end

  # Where an object of `type` (its object type, if `type` is abstract) is at `path`.
  def spot(path, object, type)
    return Spot.new(path, object, type) unless type.kind.abstract?

    resolved = @schema.sync_lazy(@query.resolve_type(type, object))
    Spot.new(path, object, resolved.is_a?(Array) ? resolved.first : resolved)
  end

  # `value` without the placeholders a field that resolved on its own selected.
  def strip(value)
    case value
    when Hash then value.tap { |object| object.delete(PLACEHOLDER) }
    when Array then value.each { |item| strip(item) }
    else value
    end
  end

  def at(path) = @tree.at(path)
end
