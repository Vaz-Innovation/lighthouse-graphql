# frozen_string_literal: true

require 'json'
require 'time'

# Writes the payloads of an incremental response as the parts of a
# `multipart/mixed` body (graphql-over-http's IncrementalDelivery RFC), to a
# response stream (ActionController::Live's `response.stream`).
#
# The body is, as the RFC has it: `\r\n---\r\n`, a part's headers and JSON, and
# so on for each part, then `\r\n-----\r\n`. Each write ends with the `---` that
# opens the next part, so a client that reads up to the next boundary has the
# part the moment it is written, not when the next one follows.
class Lighthouse::GraphQL::Incremental::Multipart
  CONTENT_TYPE = 'multipart/mixed; boundary="-"'
  PART_HEADERS = "Content-Type: application/json; charset=utf-8\r\n\r\n"

  # The headers of a streamed response: `Last-Modified` and `no-cache` keep
  # Rack::ETag from buffering it, `X-Accel-Buffering` nginx.
  def self.headers(content_type = CONTENT_TYPE)
    {
      'Content-Type' => content_type,
      'Cache-Control' => 'no-cache',
      'X-Accel-Buffering' => 'no',
      'Last-Modified' => Time.now.httpdate
    }
  end

  def initialize(stream)
    @stream = stream
    @started = false
  end

  def write(payload)
    lead = @started ? "\r\n" : "\r\n---\r\n"
    @started = true
    @stream.write("#{lead}#{PART_HEADERS}#{JSON.generate(payload)}\r\n---")
  end

  # The closing boundary. The stream is closed by ActionController::Live when the action
  # ends, after the request events, whatever happened before.
  def finish
    @stream.write("--\r\n") if @started
  end
end
