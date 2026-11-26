# frozen_string_literal: true

# A client's subscription over Server-Sent Events (graphql-sse, distinct
# connections mode): a POST that accepts `text/event-stream`, read on a thread
# of its own. `next_result` answers the data of each `next` event; `complete?`
# whether the server ended the stream.
class EventStream
  def initialize(url, query, variables: {}, token: nil)
    @events = Queue.new
    uri = URI(url)
    request = Net::HTTP::Post.new(uri.request_uri, 'Content-Type' => 'application/json', 'Accept' => 'text/event-stream')
    request['Authorization'] = "Bearer #{token}" if token
    request.body = JSON.generate(query: query, variables: variables)
    @reader = Thread.new { read(uri, request) }
  end

  # The payload of the next `next` event.
  def next_result(timeout: 15)
    loop do
      event, data = @events.pop(timeout: timeout) || raise("no event in #{timeout}s")
      raise "the stream failed: #{data}" if event == 'error'
      raise 'the stream completed' if event == 'complete'
      return JSON.parse(data) if event == 'next'
    end
  end

  # The events until the stream completes.
  def rest(timeout: 15)
    events = []
    loop do
      event, data = @events.pop(timeout: timeout) || raise("no event in #{timeout}s")
      return events if event == 'complete'

      events << JSON.parse(data) if event == 'next'
    end
  end

  def close = @reader.kill.join

  private

  def read(uri, request)
    Net::HTTP.start(uri.host, uri.port, read_timeout: 60) do |http|
      http.request(request) do |response|
        buffer = +''
        response.read_body do |chunk|
          buffer << chunk
          while (index = buffer.index("\n\n"))
            push(buffer.slice!(0, index + 2))
          end
        end
      end
    end
    @events << ['complete', nil]
  rescue StandardError => e
    @events << ['error', e.message]
  end

  # One event: its `event:` and `data:` lines (a `:` line is a keep-alive comment).
  def push(block)
    fields = block.lines(chomp: true).grep(/\A\w+:/).map { |line| line.split(/: ?/, 2) }
    return if fields.empty?

    event = fields.assoc('event')&.last || 'message'
    @events << [event, fields.filter_map { |name, value| value.to_s if name == 'data' }.join("\n")]
  end
end
