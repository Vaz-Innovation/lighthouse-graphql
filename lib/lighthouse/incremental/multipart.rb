# frozen_string_literal: true

require 'active_support/json'
require 'delegate'
require 'time'

# Writes the payloads of an incremental response as the parts of a
# `multipart/mixed` body (graphql-over-http's IncrementalDelivery RFC), to a
# response stream (ActionController::Live's `response.stream`).
#
# The body is, as the RFC has it: `\r\n---\r\n`, a part's headers and JSON, and
# so on for each part, then `\r\n-----\r\n`. Each write ends with the `---` that
# opens the next part, so a client that reads up to the next boundary has the
# part the moment it is written, not when the next one follows. A part's JSON is
# ActiveSupport's, as `render json:` writes a whole response: a Time, a BigDecimal
# or an object's `as_json` come out the same whichever the client accepts.
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

  # A streamed response as EndRequest carries it: closed, with the parts written as its body (the
  # stream's own body is the client's, which the server reads as it goes).
  class Response < SimpleDelegator
    def initialize(response, body)
      super(response)
      @body = body
    end

    attr_reader :body
  end

  def initialize(stream)
    @stream = stream
    @started = false
    @written = []
  end

  # The part of `payload`, encoded: an error raised here is the app's values'.
  def part(payload)
    "#{@started ? "\r\n" : "\r\n---\r\n"}#{PART_HEADERS}#{ActiveSupport::JSON.encode(payload)}\r\n---"
  end

  # Writes an encoded part: an error raised here is the stream's.
  def emit(part)
    @stream.write(part)
    @written << part
    @started = true
  end

  # Has a part been written?
  def started? = @started

  # The closing boundary. Closing the stream is the controller's (`ended`).
  def finish
    return unless @started

    @stream.write("--\r\n")
    @written << "--\r\n"
  end

  # `response`, its stream closed, as EndRequest carries it (Response).
  def ended(response)
    response.stream.close unless response.stream.closed?
    Response.new(response, @written.join)
  end
end
