# frozen_string_literal: true

# One operation, run in as many passes as @defer asks for.
#
#   run = Lighthouse::GraphQL::Incremental::Run.new(schema, query, variables: {}, context: {}).start
#   run.result                   # the first pass, as `schema.execute` answers it
#   run.deferred?                # fragments are pending
#   run.each_payload { |payload| ... }   # the initial payload, then one per round
#
# `start` runs the client's document as it came, through the schema's `execute` (an
# app's own too), parsed once, as a GraphQL::Query whose `query_string` is the client's: validation, analysis
# (complexity, depth, and Rules, which checks @defer and @stream), listeners and
# tracing see what they would without @defer. DeferDirective leaves the deferred
# fragments out of the execution, and State keeps them.
#
# Then it goes in rounds, as PHP Lighthouse's Defer: each round runs every
# fragment pending, on the object it was found on, as Plan cuts them into units
# (GraphQL::Query::Partial), all in one `schema.multiplex` so the Dataloader batches
# across them (and in a pass after it, those Plan plans below the object fields they
# resolve), and is one payload; the fragments they hold are announced in it, and
# make the next round. A field resolves once: what the response already holds is not
# run again, and a mutation does not run again (PHP Lighthouse runs the whole
# query again each round).
#
# PHP Lighthouse's limits, 0 for none: past Config.defer_max_nested_fields rounds,
# or once Config.defer_max_execution_ms milliseconds have gone since the first
# pass started, the round that runs is the last: the fragments it holds run
# where they stand, and its lists are answered whole.
#
# A client that does not stream is answered by `schema.execute`, the whole
# response at once, as the specification allows.
#
# The payloads are the draft's (Serializer); with `format: :legacy`, the client is sent each in
# Apollo's older format instead (Legacy).
class Lighthouse::GraphQL::Incremental::Run
  State = Lighthouse::GraphQL::Incremental::State
  Serializer = Lighthouse::GraphQL::Incremental::Serializer

  attr_reader :result

  # `options`: `schema.execute`'s (variables:, operation_name:, context:, ...). `format`: the
  # payloads' (:draft, or :legacy for Apollo's older one).
  def initialize(schema, query_string, format: :draft, **options)
    @schema = schema
    @query_string = query_string
    @options = options
    @queue = []
    @announced = []
    @pendings = {}
    @legacy = Lighthouse::GraphQL::Incremental::Legacy.new(@pendings) if format == :legacy
    @next_id = 0
    @running = []
    @round = 0
    @errors = []
    @open = {}
    @found = Set.new
  end

  # Runs the first pass. The block, if given, gets what ends the operation (`finish`): the first
  # pass's result when nothing is deferred, at once; else the whole response, once the last
  # payload is out (or `finish` is called).
  def start(&finished)
    seconds = Lighthouse::Config.defer_max_execution_ms / 1000.0
    @deadline = clock + seconds if seconds.positive?
    @result = execute
    @finished = finished
    @streams = deferred?
    finish unless @streams
    self
  end

  # Fragments are pending: the response goes in more than one payload.
  def deferred?
    !@queue.empty?
  end

  # The initial payload, then each later one, until `hasNext` is false. A later payload that
  # fails, to run or to be written (the block raised: its app values did not encode), ends the
  # stream with a last payload, which completes, with an error, every id the client was sent and
  # has not seen completed, then raises again. A first payload that fails raises, nothing being
  # sent. `finish` is the caller's, once it has closed the stream (PersistedQueries.incremental
  # calls it once its block is done), so the operation ends after the response does.
  #
  # A client that went away (Gone, raised by the block) stops it: nothing more is written, and
  # the operation ends with what the client was sent. An error of the app's stays the error
  # raised, even if the client has gone by the time its last payload is written.
  def each_payload(&block)
    @streaming = true
    first(&block)
    until @queue.empty?
      begin
        emit(next_payload, &block)
      rescue Lighthouse::GraphQL::Incremental::Gone
        raise
      rescue StandardError => e
        fail_stream(e, &block)
      end
    end
  end

  # The whole response as the client put it together: the data and the errors of every payload
  # it was sent (the first pass's first), the first pass's extensions. When nothing was sent: an
  # empty Hash if the client left before the first payload, the error the JSON path would answer
  # (Internal server error) if that payload failed.
  def response
    return @refused ? { 'errors' => [{ 'message' => 'Internal server error' }] } : {} if @streaming && !@delivered

    first = @result.to_h
    { 'data' => @sent || first['data'], 'errors' => (first['errors'].to_a + @errors).presence, 'extensions' => first['extensions'] }.compact
  end

  # The first payload, as the client is sent it (each_payload yields this one first): one that
  # does not encode can be refused before anything is sent.
  def first_payload = @first_payload ||= formatted(initial_payload)

  # The first payload could not be sent (it did not encode, so nothing was): the operation
  # ends as one that failed (`response`).
  def refuse! = (@streaming = @refused = true)

  # Calls the block `start` was given, once: with the first pass's result when nothing was
  # deferred, else with the response so far.
  def finish
    finished = @finished
    @finished = nil
    finished&.call(@streams ? response : @result)
  end

  private

  # The initial payload: one that fails, but for a client gone, is refused (`response`).
  def first(&block)
    emit(initial_payload, formatted: first_payload, &block)
  rescue StandardError => e
    @refused = !e.is_a?(Lighthouse::GraphQL::Incremental::Gone)
    raise
  end

  # The first pass is the schema's `execute`, as the JSON path runs a query (an app's own
  # `execute` too, with what it adds to the context): graphql-ruby parses the query once,
  # through the schema's trace, and answers one that does not parse. A State goes in the
  # context of a query that may use @defer or @stream (Document::INCREMENTAL, on the text: a
  # false positive costs an unused State), and reads the document of the query it finds there
  # (State#bind). An `execute` that runs the query without that context, or answers no
  # GraphQL::Query::Result, defers nothing: the response comes whole.
  def execute
    @state = State.new if Lighthouse::GraphQL::Incremental::Document::INCREMENTAL.match?(@query_string.to_s) && traced?
    result = running { @schema.execute(@query_string, **@options.except(:context), context: query_context) }
    query = result.query if result.respond_to?(:query)
    @state = nil unless query.is_a?(::GraphQL::Query) && query.context[State::CONTEXT_KEY].equal?(@state)
    return result unless @state

    @state.bind(query)
    @tree = Lighthouse::GraphQL::Incremental::Tree.new(result.to_h['data'])
    announce(@state.drain(query))
    result
  end

  # The app's context, as it gave it; with the State, a copy of it, so that its Hash is left
  # as it was.
  def query_context
    context = @options[:context]
    @state ? (context || {}).merge(State::CONTEXT_KEY => @state) : context
  end

  # What Schema.execute hands its multiplex of the query's context: a new Hash each time, where
  # graphql-ruby puts the multiplex's dataloader and trace, so each round gets its own.
  def multiplex_context
    context = @options[:context] || {}
    { backtrace: context[:backtrace], tracers: context[:tracers], trace: context[:trace], dataloader: context[:dataloader],
      trace_mode: context[:trace_mode] }
  end

  # Does the trace the request runs with hold StreamTrace (in every mode, unless the app gave a
  # trace class of its own that leaves out the schema's trace modules)? Without it nothing is
  # streamed: the response comes whole.
  def traced?
    context = @options[:context] || {}
    trace = context[:trace] || @schema.trace_class_for(context[:trace_mode] || @schema.default_trace_mode, build: true)
    (trace.is_a?(Module) ? trace : trace.class).include?(Lighthouse::GraphQL::Incremental::StreamTrace)
  end

  # Runs a multiplex with the State in StreamTrace's fiber-local RUNNING.
  def running
    previous = Thread.current[Lighthouse::GraphQL::Incremental::StreamTrace::RUNNING]
    Thread.current[Lighthouse::GraphQL::Incremental::StreamTrace::RUNNING] = @state
    yield
  ensure
    Thread.current[Lighthouse::GraphQL::Incremental::StreamTrace::RUNNING] = previous
  end

  # The next round: every pending fragment and list, run together.
  def next_payload
    @round += 1
    @state.deferring = deferring?
    @running = @queue
    @queue = []
    plan = Lighthouse::GraphQL::Incremental::Plan.new(@result.query, @state, @tree)
    units, partials, responses = passes(plan)
    outcome = Lighthouse::GraphQL::Incremental::Delivery.new(@state, @tree).call(units, partials, responses)
    @unsent = outcome.errors
    found(plan, units, partials, outcome.failed)
    completed = @running.map { |pending| { 'id' => pending.id, 'errors' => outcome.failed[pending] }.compact }
    Serializer.subsequent(incremental: outcome.incremental, completed: completed, extensions: outcome.extensions,
                          pending: @announced, has_next: deferred?)
  end

  # The round's units, their partials and their responses: each pass's, until Plan has no more.
  def passes(plan)
    units = plan.units(@running)
    all = [[], [], []]
    until units.empty?
      partials = units.map { |unit| unit.partial(@result.query, @state) }
      responses = run(partials)
      [units, partials, responses].each_with_index { |list, index| all[index].concat(list) }
      units = plan.follow(units, responses)
    end
    all
  end

  # Announce the fragments the round found, but those found only in fragments that `failed`: by
  # Plan, in the fragments `parents`, and by each unit's Partial, in those the unit serves.
  def found(plan, units, partials, failed)
    @announced = []
    lost = ->(pendings) { pendings.all? { |pending| failed.key?(pending) } }
    found = @state.drain(plan).reject { |pending| lost.call(pending.parents) }
    units.each_with_index do |unit, index|
      drained = @state.drain(partials[index])
      found.concat(drained) unless lost.call(unit.pendings)
    end
    announce(found)
  end

  # May the fragments of this round defer the fragments they hold? Not past the limits:
  # with defer_max_nested_fields 1, the first round resolves everything left.
  def deferring?
    max = Lighthouse::Config.defer_max_nested_fields
    return false if max.positive? && @round >= max

    @deadline.nil? || clock < @deadline
  end

  def clock = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  # The responses of the partials, run in one multiplex so the Dataloader batches across them.
  # The first pass analyzed the whole document: no max_complexity again, which analysis
  # cannot apply to a Partial.
  def run(partials)
    running { @schema.multiplex(partials, context: multiplex_context, max_complexity: nil).map(&:to_h) }
  end

  # Give the fragments found their ids, and queue them: each once at a path (a fragment spread
  # twice on an object, or found by two units, is deferred once). Those whose object an error
  # nulled out of the response are dropped.
  def announce(found)
    found.each do |pending|
      next unless present?(pending.path) && @found.add?([pending.node.object_id, pending.path])

      pending.id = @next_id.to_s
      @pendings[pending.id] = pending
      @next_id += 1
      @queue << pending
      @announced << pending
    end
  end

  # Does `path` lead to a value in the response's data so far?
  def present?(path) = @tree.present?(path)

  # Yields a payload, as the client is sent it (`formatted`), and keeps what the client was sent:
  # the ids it has not seen completed, the data and the errors.
  # A failure's payload sends no data (`data: false`).
  def emit(payload, data: true, formatted: formatted(payload))
    yield formatted
    @delivered = true
    payload['pending'].to_a.each { |entry| @open[entry['id']] = true }
    payload['completed'].to_a.each { |entry| @open.delete(entry['id']) }
    @sent = @tree&.snapshot if data
    @errors.concat(@unsent.to_a)
    @unsent = nil
  end

  # The first payload, in the draft's format.
  def initial_payload = @initial_payload ||= Serializer.initial(@result, @announced, has_next: deferred?)

  # The draft's payload as the client reads it.
  def formatted(payload) = @legacy ? @legacy.convert(payload) : payload

  # A stream that failed ends with a last payload, in which every id still open completes, with an
  # error; then `error` is raised again, whether or not the client could be sent that payload.
  def fail_stream(error, &block)
    errors = [{ 'message' => 'Internal server error' }]
    @unsent = errors
    completed = @open.keys.map { |id| { 'id' => id, 'errors' => errors } }
    payload = Serializer.subsequent(incremental: [], completed: completed, pending: [], has_next: false)
    begin
      emit(payload, data: false, &block)
    rescue Lighthouse::GraphQL::Incremental::Gone
      nil
    end
    raise error
  end
end
