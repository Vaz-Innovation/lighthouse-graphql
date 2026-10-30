# frozen_string_literal: true

# The body of a streamed response: a Rack body the server iterates, writing each part of the
# `multipart/mixed` response as Run answers its payload, as Rails streams a template
# (`self.response_body =`): in the request's thread, inside its executor, with no thread of its
# own. The action has returned by then: what happens next is the body's.
#
# The first part was encoded in the action (`first`), where an error is answered as the JSON
# path answers it. Then each round runs as the server asks for the next part. Whatever fails, the
# stream ends here: Run has yielded the last payload an error ends it with, the error is reported
# (`on_error`) and goes no further, as the response is on its way, and the closing boundary is
# written. A client that went away (the server's write raised) ends it quietly. Last, as the
# body is done (`finish`, once), the operation ends (Run#finish), then the request (`on_end`).
#
# Rails maps a Rack body's `close` to nothing (Response#abort), so `finish` runs when `each`
# is done, and from the server's `rack.response_finished` callbacks, where there are, for a body
# never iterated.
class Lighthouse::GraphQL::Incremental::Body
  Gone = Lighthouse::GraphQL::Incremental::Gone

  def initialize(run, multipart, first, on_error:, on_end:)
    @run = run
    @multipart = multipart
    @first = first
    @on_error = on_error
    @on_end = on_end
  end

  def each(&write)
    @run.each_payload { |payload| emit(write, payload.equal?(@run.first_payload) ? @first : @multipart.part(payload)) }
    emit(write, @multipart.closing)
  rescue Gone
    nil
  rescue StandardError => e
    @on_error.call(e)
    close_after(write)
  ensure
    finish
  end

  # Ends the operation, then the request, once.
  def finish
    return if @finished

    @finished = true
    begin
      @run.finish
    ensure
      @on_end.call
    end
  end

  private

  # Writes a part. An error the server raises writing it is a client gone (Gone).
  def emit(write, part)
    return unless part

    begin
      write.call(part)
    rescue StandardError
      raise Gone
    end
    @multipart.written(part)
  end

  # The closing boundary of a stream an error ended, once that error was reported: a client gone
  # by then ends it quietly, and an error writing it is reported in turn.
  def close_after(write)
    emit(write, @multipart.closing)
  rescue Gone
    nil
  rescue StandardError => e
    @on_error.call(e)
  end
end
