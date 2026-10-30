# frozen_string_literal: true

# The payloads of an incremental response in Apollo's older format, the one graphql-js
# 17.0.0-alpha.2 answered and a client names with `deferSpec=20220824` in its Accept header
# (Apollo Client 3, Apollo Client 4's Defer20220824Handler). Run answers the draft's payloads
# (Serializer); this converts each, as the client is sent it.
#
# The first payload is the first pass's result and `hasNext`, without `pending`. Each later one
# has `incremental`: for a fragment, its `data` at the `path` of its object (the draft's `path`
# and `subPath`), with its `label`; for a stream, its `items` at the path of the list and the
# index of its first item. A fragment or a stream that failed sends `data` (or `items`) null,
# with its `errors`. A fragment that completes with nothing of its own to send (the response
# already holds it) is sent as empty data at its path, so that the client hears of each one.
class Lighthouse::GraphQL::Incremental::Legacy
  # `pendings`: the fragments and streams the client was told of, by id (Run's, as it announces them).
  def initialize(pendings)
    @pendings = pendings
    @initial = true
  end

  # The payload of the draft's format, in this one.
  def convert(payload)
    return initial(payload) if @initial

    entries = payload['incremental'].to_a
    sent = entries.to_set { |entry| entry['id'] }
    subsequent(entries.map { |entry| entry(entry) } + payload['completed'].to_a.filter_map { |done| completion(done, sent) }, payload)
  end

  private

  # What tells the client of a fragment or a stream done: its failure, or, for a fragment that
  # sent nothing (`sent`: the ids of the payload's entries), its empty data; else nothing.
  def completion(done, sent)
    pending = @pendings.fetch(done['id'])
    return failure(pending, done['errors']) if done['errors']

    { 'data' => {}, 'path' => pending.path, 'label' => pending.label }.compact unless stream?(pending) || sent.include?(done['id'])
  end

  def initial(payload)
    @initial = false
    payload.except('pending')
  end

  def subsequent(incremental, payload)
    converted = {}
    converted['incremental'] = incremental unless incremental.empty?
    converted['extensions'] = payload['extensions'] if payload['extensions']
    converted['hasNext'] = payload['hasNext']
    converted
  end

  def entry(entry)
    pending = @pendings.fetch(entry['id'])
    converted = if entry.key?('items')
                  { 'items' => entry['items'], 'path' => items_path(pending) }
                else
                  { 'data' => entry['data'], 'path' => pending.path + entry['subPath'].to_a }
                end
    converted.merge({ 'label' => pending.label, 'errors' => entry['errors'], 'extensions' => entry['extensions'] }.compact)
  end

  def failure(pending, errors)
    key = stream?(pending) ? 'items' : 'data'
    { key => nil, 'path' => stream?(pending) ? items_path(pending) : pending.path, 'label' => pending.label, 'errors' => errors }
      .reject { |name, value| name == 'label' && value.nil? }
  end

  # A stream's are announced with the index its later items start at (`initialCount`).
  def stream?(pending) = !pending.offset.nil?

  # The path of a stream's first later item: the list's, and its index.
  def items_path(pending) = pending.path + [pending.offset]
end
