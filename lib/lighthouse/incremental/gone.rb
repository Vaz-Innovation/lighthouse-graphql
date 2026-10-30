# frozen_string_literal: true

# The client of a streamed response went away: writing to its stream failed (the
# controller raises it from the write). Run stops there, writes nothing more, and
# ends the operation with what the client was sent.
class Lighthouse::GraphQL::Incremental::Gone < StandardError; end
