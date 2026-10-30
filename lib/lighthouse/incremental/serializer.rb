# frozen_string_literal: true

# The payloads of an incremental response, in the format of the specification
# draft (graphql-spec PR #1110, section 7). The only place that knows it: if the
# draft changes, this file does.
#
# The first payload is the result of the first pass, plus `pending` (one entry,
# with a string `id`, for every fragment that will follow) and `hasNext`. Each
# later one has `incremental` (the data of a fragment, or the items of a stream,
# under their `id`), `completed` (the ids that are done, with their `errors` when
# they failed), the `pending` it announces, and `hasNext`. The last has
# `hasNext: false`.
module Lighthouse::GraphQL::Incremental::Serializer
  module_function

  # `result`: the first pass's response Hash.
  def initial(result, pending, has_next:)
    result.to_h.merge('pending' => pending.map { |entry| pending_entry(entry) }, 'hasNext' => has_next)
  end

  # `incremental`: Hashes with an `id` and `data` or `items` (and `errors`, `extensions`);
  # `completed`: Hashes with an `id` (and `errors`); `extensions`: the payload's own.
  def subsequent(incremental:, completed:, pending:, has_next:, extensions: {})
    payload = {}
    payload['pending'] = pending.map { |entry| pending_entry(entry) } unless pending.empty?
    payload['incremental'] = incremental unless incremental.empty?
    payload['completed'] = completed unless completed.empty?
    payload['extensions'] = extensions unless extensions.empty?
    payload['hasNext'] = has_next
    payload
  end

  # An entry of `pending`: the Hash it is answered with. A label that was not given is left out.
  def pending_entry(entry)
    { 'id' => entry.id, 'path' => entry.path, 'label' => entry.label }.compact
  end
end
