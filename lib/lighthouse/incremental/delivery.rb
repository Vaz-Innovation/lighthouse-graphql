# frozen_string_literal: true

# What a round delivers (Run#next_payload), from the responses of its units
# (Plan): the `incremental` entries, the fragments and lists that failed, with
# their errors, and the payload's own `extensions`. The data it delivers goes in
# the response's Tree.
#
# A pending fragment's delivery is all or nothing, as the draft has it: a
# fragment completed with errors delivers no data. One of its units that leaves
# no data (a non-null field failed beyond the unit's root) fails the fragment,
# and every unit of it is withheld; a unit that serves several fragments (Plan
# lets one take a field another asks for too) fails them all.
#
# An entry that carries nothing (no data, or no items, and no errors) is not
# sent: its extensions, and those of a withheld unit, go on the payload's.
class Lighthouse::GraphQL::Incremental::Delivery
  Outcome = Struct.new(:incremental, :failed, :extensions, :errors, :delivered, keyword_init: true)

  def initialize(state, tree)
    @state = state
    @tree = tree
  end

  # `units`, `partials`, `responses`: the round's, in the same order.
  def call(units, partials, responses)
    responses = responses.each_with_index.map { |response, index| absolute(units[index], partials[index], response) }
    failed = failures(units, responses)
    outcome = Outcome.new(incremental: [], failed: failed, extensions: {}, errors: responses.flat_map { |response| response['errors'].to_a },
                          delivered: {}.compare_by_identity)
    units.each_with_index { |unit, index| deliver(unit, partials[index], responses[index], outcome) }
    outcome
  end

  private

  def deliver(unit, partial, response, outcome)
    entry = entry(unit, response) unless unit.pendings.any? { |pending| outcome.failed.key?(pending) }
    return outcome.extensions.merge!(response['extensions'].to_h) unless entry && carries?(entry)

    unit.stream? ? @tree.append(unit.path, entry['items']) : @tree.merge(unit.path, entry['data'])
    outcome.incremental << entry
    outcome.delivered[partial] = true
  end

  # A unit's entry: a stream's `items`, or data below its fragment's path at its `subPath`, with the
  # errors and the extensions of its run (BuildExtensionsResponse, ManipulateResult).
  def entry(unit, response)
    data, errors, extensions = response.values_at('data', 'errors', 'extensions')
    sub_path = unit.sub_path unless unit.stream? || unit.sub_path.empty?
    { 'id' => unit.owner.id, 'subPath' => sub_path, (unit.stream? ? 'items' : 'data') => data, 'errors' => errors,
      'extensions' => extensions }.compact
  end

  def carries?(entry) = !(entry['data'] || entry['items']).empty? || entry.key?('errors')

  # The pending fragments and lists that failed, with their errors: those of a unit that left no
  # data, and, until none is left, those of a unit that serves one that failed.
  def failures(units, responses)
    failed = {}.compare_by_identity
    units.each_with_index { |unit, index| mark(unit, responses[index]['errors'].to_a, failed) if responses[index]['data'].nil? }
    loop do
      spread = units.select { |unit| partly?(unit, failed) }
      break if spread.empty?

      spread.each { |unit| mark(unit, unit.pendings.flat_map { |pending| failed[pending].to_a }.uniq, failed) }
    end
    withheld(units, responses, failed)
  end

  # Does the unit serve a fragment that failed, and one that has not yet?
  def partly?(unit, failed)
    unit.pendings.any? { |pending| failed.key?(pending) } && !unit.pendings.all? { |pending| failed.key?(pending) }
  end

  # The errors of a withheld unit that left data are its fragments' too.
  def withheld(units, responses, failed)
    units.each_with_index do |unit, index|
      next if responses[index]['data'].nil? || unit.pendings.none? { |pending| failed.key?(pending) }

      mark(unit, responses[index]['errors'].to_a, failed)
    end
    failed
  end

  # The unit's fragments failed, with `errors`.
  def mark(unit, errors, failed)
    unit.pendings.each { |pending| failed[pending] = (failed[pending].to_a + errors).uniq }
  end

  # A stream's errors count its items from the first one its Partial ran: their paths, as the response's.
  def absolute(unit, partial, response)
    return response unless unit.stream? && response['errors']

    response['errors'].each { |error| error['path'] = @state.absolute(partial, error['path']) if error['path'] }
    response
  end
end
