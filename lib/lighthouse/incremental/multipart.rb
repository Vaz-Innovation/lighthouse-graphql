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
  # stream's own body is the client's, which the server reads as it goes), joined when read.
  class Response < SimpleDelegator
    def initialize(response, parts)
      super(response)
      @parts = parts
    end

    def body = @body ||= @parts.join
  end

  # `keep`: keep the parts written, for EndRequest's body (only when something listens to it).
  def initialize(stream, keep: true)
    @stream = stream
    @started = false
    @opened = false
    @written = keep ? [] : nil
  end

  # The part of `payload`, encoded: an error raised here is the app's values'.
  def part(payload)
    "#{@started ? "\r\n" : "\r\n---\r\n"}#{PART_HEADERS}#{ActiveSupport::JSON.encode(payload)}\r\n---"
  end

  # Writes an encoded part: an error raised here is the stream's.
  def emit(part)
    @opened = true
    @stream.write(part)
    @written&.push(part)
    @started = true
  end

  # Has a part been written?
  def started? = @started

  # Was a part written, or tried: the response committed, its stream the request's to close?
  def opened? = @opened

  # The closing boundary. Closing the stream is the controller's (`ended`).
  def finish
    return unless @started

    @stream.write("--\r\n")
    @written&.push("--\r\n")
  end

  # `response`, its stream closed, as EndRequest carries it (Response): its body the parts kept.
  def ended(response)
    close(response)
    Response.new(response, @written.to_a)
  end

  # Closes `response`'s stream, once a part was written or tried (opened?), unless it is closed.
  def close(response)
    response.stream.close if @opened && !response.stream.closed?
  end
end
