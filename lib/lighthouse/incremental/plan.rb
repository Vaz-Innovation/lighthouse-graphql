# frozen_string_literal: true

# What a round of incremental delivery runs (Run#next_payload): the units of
# work of its pending fragments and lists, each a GraphQL::Query::Partial.
#
# As the specification draft has it, a deferred fragment's fields that the
# response already holds at its path (the rest of the query asked for them, or
# another fragment delivered them) are neither resolved nor sent again: each
# field resolves once. The fragments of a round at one path make one unit, with
# what none of them was sent yet; a field two of them select is sent once. An
# object field the response already holds, to which a fragment adds selections,
# is not resolved again either: its object (kept by StreamTrace when it
# resolved) gets a unit of its own, sent at its `subPath`.
#
# The deferred fragments nested in a unit's fragments, at the same path, are found
# here and pending for the next round, without a pass to find them.
class Lighthouse::GraphQL::Incremental::Plan
  Nodes = ::GraphQL::Language::Nodes
  State = Lighthouse::GraphQL::Incremental::State
  KNOWN = %w[skip include defer].freeze

  # The object a fragment adds selections to was not kept (StreamTrace keeps every one a fragment
  # may need before it resolves): a bug, which fails the round.
  class Lost < StandardError; end

  # A Partial's work: `selections` on `object` (of `type`) at `path`, delivered for `owner`
  # (with the other `pendings` of its path, which complete with it). A stream's: its items.
  Unit = Struct.new(:owner, :pendings, :path, :object, :type, :selections, keyword_init: true) do
    def stream? = owner.stream?
    def sub_path = path.drop(owner.path.size)
  end

  # Where a unit runs: on `object`, of the object type `type`, at `path`, for the pending `group`.
  Spot = Struct.new(:path, :object, :type, :group)

  # `tree`: the response's data so far, as the client has merged it.
  def initialize(query, state, tree)
    @query = query
    @state = state
    @document = state.document
    @schema = query.schema
    @tree = tree
    @claims = {}
    @units = []
  end

  def units(pendings)
    streams, fragments = pendings.partition(&:stream?)
    streams.each do |pending|
      @units << Unit.new(owner: pending, pendings: [pending], path: pending.path, object: pending.object, type: pending.list_type)
    end
    fragments.group_by(&:path).sort_by { |path, _| path.size }.each do |path, group|
      plan(group.flat_map { |pending| @document.selections(pending.node) }, Spot.new(path, group.first.object, group.first.type, group))
    end
    @units
  end

  private

  def plan(selections, spot)
    group = spot.group
    held = at(spot.path)
    held = nil unless held.is_a?(Hash)
    kept, shared = split(selections, held, spot)
    claim(spot, kept, group) unless kept.empty?
    shared.each { |key, fields| descend(key, fields, held[key], spot) unless fields.empty? || held[key].nil? }
  end

  # The selections the response does not hold yet (`kept`), and, by response key, the object
  # fields it holds to which they add selections (`shared`). Fragments are evaluated here and
  # flattened; a deferred one is pending for the next round instead.
  def split(selections, held, spot)
    shared = Hash.new { |hash, key| hash[key] = [] }
    kept = flatten(selections, spot).select { |selection| keep?(selection, held, spot, shared) }
    [kept, shared]
  end

  # A field the response does not hold, which no other unit of the round claims. Those it holds
  # go to `shared` (with selections); those another unit claims go to that unit, which then
  # serves this group too (and fails it, if it fails: Delivery).
  def keep?(selection, held, spot, shared)
    return true unless selection.is_a?(Nodes::Field)

    key = selection.alias || selection.name
    return share(selection, shared[key]) if held.is_a?(Hash) && held.key?(key)

    unit = @claims.dig(spot.path, key) or return true
    unit.pendings |= spot.group
    unit.selections << selection unless selection.selections.empty?
    false
  end

  # A field the response holds: one with selections may add some to its object.
  def share(selection, fields)
    fields << selection unless selection.selections.empty?
    false
  end

  # The fields `selections` select on the object, through the fragments that apply to it;
  # a fragment with a directive other than @skip, @include or @defer is kept as it is.
  def flatten(selections, spot)
    selections.flat_map do |selection|
      next [] unless @document.included?(selection, @query)

      selection.is_a?(Nodes::Field) ? [selection] : fragment(selection, spot)
    end
  end

  def fragment(fragment, spot)
    return [] unless @document.applies?(fragment, spot.type, @query)
    return defer(fragment, spot) if @state.deferring && @document.deferred?(fragment, @query)
    return [fragment] if fragment.directives.any? { |directive| KNOWN.exclude?(directive.name) }

    flatten(@document.selections(fragment), spot)
  end

  def defer(fragment, spot)
    directive = fragment.directives.find { |candidate| candidate.name == 'defer' }
    label = @query.arguments_for(directive, @schema.directives['defer'])[:label]
    @state.found(self,
                 State::Pending.new(node: fragment, object: spot.object, type: spot.type, path: spot.path, label: label, parent: spot.group.first))
    []
  end

  # The units of the selections `fields` add to the object (or each object of the list) the
  # response holds at `key`.
  def descend(key, fields, held, spot)
    type = @schema.get_field(spot.type, fields.first.name)&.type&.unwrap or return
    value = @state.object_at(spot.path + [key])
    raise Lost, "Lighthouse kept no object at #{(spot.path + [key]).join('.')}" if value.equal?(State::MISSING)

    selections = fields.flat_map(&:selections)
    targets(spot.path + [key], value, held).each { |path, object| plan(selections, Spot.new(path, object, concrete(type, object), spot.group)) }
  end

  # The object at `path`, or those of the list there (the response holds `held`), each with its
  # path; none where the response holds null.
  def targets(path, value, held)
    return [[path, value]] unless held.is_a?(Array)

    objects = value.respond_to?(:to_a) ? value.to_a : []
    held.each_index.filter_map { |index| [path + [index], objects[index]] unless held[index].nil? || objects[index].nil? }
  end

  # The object type of `object`, a value of `type`.
  def concrete(type, object)
    return type unless type.kind.abstract?

    resolved = @schema.sync_lazy(@query.resolve_type(type, object))
    resolved.is_a?(Array) ? resolved.first : resolved
  end

  def claim(spot, selections, group)
    unit = Unit.new(owner: group.first, pendings: group, path: spot.path, object: spot.object, type: spot.type, selections: selections)
    @units << unit
    keys = @claims[unit.path] ||= {}
    unit.selections.each { |selection| keys[selection.alias || selection.name] ||= unit if selection.is_a?(Nodes::Field) }
  end

  def at(path) = @tree.at(path)
end
