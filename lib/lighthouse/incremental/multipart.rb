# frozen_string_literal: true

require 'active_support/json'
require 'delegate'
require 'time'

# The parts of a `multipart/mixed` body (graphql-over-http's IncrementalDelivery RFC), one for
# each payload of an incremental response, as Body writes them.
#
# The body is, as the RFC has it: `\r\n---\r\n`, a part's headers and JSON, and so on for each
# part, then `\r\n-----\r\n`. Each part ends with the `---` that opens the next one, so a client
# that reads up to the next boundary has the part the moment it is written, not when the next
# one follows. A part's JSON is ActiveSupport's, as `render json:` writes a whole response: a
# Time, a BigDecimal or an object's `as_json` come out the same whichever the client accepts.
class Lighthouse::GraphQL::Incremental::Multipart
  CONTENT_TYPE = 'multipart/mixed; boundary="-"'
  PART_HEADERS = "Content-Type: application/json; charset=utf-8\r\n\r\n"
  CLOSING = "--\r\n"

  # The headers of a streamed response. `no-store` keeps it from any cache, and so from a
  # conditional GET, and `Last-Modified` keeps Rack::ETag from buffering it; `X-Accel-Buffering`
  # nginx.
  def self.headers(content_type = CONTENT_TYPE)
    {
      'Content-Type' => content_type,
      'Cache-Control' => 'no-store',
      'X-Accel-Buffering' => 'no',
      'Last-Modified' => Time.now.httpdate
    }
  end

  # The parts of a multipart/mixed body: each payload's JSON, between boundaries.
  def self.parse(body)
    body.to_s.split(/\r\n-{3,5}(?:\r\n|\z)/).filter_map do |part|
      json = part.split("\r\n\r\n", 2)[1]
      JSON.parse(json) if json && !json.strip.empty?
    end
  end

  # A streamed response as EndRequest carries it: its body the parts written (the client read
  # the response's own as it went), joined when read.
  class Response < SimpleDelegator
    def initialize(response, parts)
      super(response)
      @parts = parts
    end

    def body = @body ||= @parts.join
  end

  # `keep`: keep the parts written, for EndRequest's body (only when something listens to it).
  def initialize(keep: true)
    @started = false
    @written = keep ? [] : nil
  end

  # The part of `payload`, encoded: an error raised here is the app's values'.
  def part(payload)
    "#{@started ? "\r\n" : "\r\n---\r\n"}#{PART_HEADERS}#{ActiveSupport::JSON.encode(payload)}\r\n---"
  end

  # A part (or the closing boundary) was written.
  def written(part)
    @written&.push(part)
    @started = true
  end

  # Has a part been written?
  def started? = @started

  # The closing boundary, once a part was written.
  def closing = (CLOSING if @started)

  # `response` as EndRequest carries it (Response): its body the parts kept.
  def ended(response) = Response.new(response, @written.to_a)
end
