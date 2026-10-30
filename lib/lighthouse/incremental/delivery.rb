# frozen_string_literal: true

# What a round delivers (Run#next_payload), from the responses of its units
# (Plan): the `incremental` entries, the fragments and lists that failed, with
# their errors, and the payload's own `extensions`. The data it delivers goes in
# the response's Tree.
#
# A unit is what the draft calls a grouped field set: its data belongs to every
# pending fragment it serves (`pendings`: those that select its fields). A
# fragment fails when a unit it depends on leaves no data (a non-null field
# failed beyond the unit's root), and a fragment that fails delivers no data, as
# the draft has it: a unit that serves only fragments that failed is withheld. A
# unit that also serves one that did not is delivered, under the id of that one:
# the field it shares reaches the client through the fragment that succeeded.
# Another fragment's failure does not fail a fragment.
#
# A stream fails when an item it delivers is null (or an error nulls it) where the
# list's items are non-null, as the list would have in one response.
#
# An entry that carries nothing (no data, or no items, and no errors) is not
# sent: its extensions, and those of a withheld unit, go on the payload's.
class Lighthouse::GraphQL::Incremental::Delivery
  Outcome = Struct.new(:incremental, :failed, :extensions, :errors, keyword_init: true)

  def initialize(state, tree)
    @state = state
    @tree = tree
  end

  # `units`, `partials`, `responses`: the round's, in the same order.
  def call(units, partials, responses)
    responses = responses.each_with_index.map { |response, index| restore(units[index], partials[index], response) }
    outcome = Outcome.new(incremental: [], failed: failures(units, responses), extensions: {})
    units.each_with_index { |unit, index| deliver(unit, responses[index], outcome) }
    outcome.errors = outcome.incremental.flat_map { |entry| entry['errors'].to_a } + outcome.failed.values.flatten.uniq
    outcome
  end

  private

  def deliver(unit, response, outcome)
    owner = unit.pendings.find { |pending| !outcome.failed.key?(pending) } unless response['data'].nil?
    return withhold(unit, response, outcome) unless owner

    entry = entry(unit, owner, response)
    return outcome.extensions.merge!(response['extensions'].to_h) unless carries?(entry)

    unit.stream? ? @tree.append(unit.path, entry['items']) : @tree.merge(unit.path, entry['data'])
    outcome.incremental << entry
  end

  # A unit no fragment that did not fail is left to deliver: its errors are its fragments'.
  def withhold(unit, response, outcome)
    unit.pendings.each { |pending| outcome.failed[pending] = (outcome.failed[pending] + response['errors'].to_a).uniq } unless response['data'].nil?
    outcome.extensions.merge!(response['extensions'].to_h)
  end

  # A unit's entry, under `owner`'s id: a stream's `items`, or data below the fragment's path at
  # its `subPath`, with the errors and the extensions of its run (BuildExtensionsResponse,
  # ManipulateResult).
  def entry(unit, owner, response)
    data, errors, extensions = response.values_at('data', 'errors', 'extensions')
    sub_path = unit.path.drop(owner.path.size) unless unit.stream?
    { 'id' => owner.id, 'subPath' => sub_path.presence, (unit.stream? ? 'items' : 'data') => data, 'errors' => errors,
      'extensions' => extensions }.compact
  end

  def carries?(entry) = !(entry['data'] || entry['items']).empty? || entry.key?('errors')

  # The pending fragments and lists that failed, with their errors: those a unit that left no data serves.
  def failures(units, responses)
    failed = {}.compare_by_identity
    units.each_with_index do |unit, index|
      next unless responses[index]['data'].nil?

      unit.pendings.each { |pending| failed[pending] = (failed[pending].to_a + responses[index]['errors'].to_a).uniq }
    end
    failed
  end

  # A stream's response as the list's: its errors' paths, which count the items its Partial ran
  # from 0, as the response's, and its items, the field's list. A list an error nulled (a null
  # item where its items are non-null) fails the stream.
  def restore(unit, partial, response)
    return response unless unit.stream?

    response['errors'].to_a.each { |error| absolute(partial, error) }
    response.merge('data' => response['data']&.fetch(unit.path.last, nil))
  end

  def absolute(partial, error)
    error['path'] = @state.absolute(partial, error['path']) if error['path']
  end
end
