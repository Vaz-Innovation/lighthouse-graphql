# frozen_string_literal: true

# One operation, run in as many passes as @defer asks for.
#
#   run = Lighthouse::GraphQL::Incremental::Run.new(schema, query, variables: {}, context: {}).start
#   run.result                   # the first pass, as `schema.execute` answers it
#   run.deferred?                # fragments are pending
#   run.each_payload { |payload| ... }   # the initial payload, then one per round
#
# `start` parses the query once and runs the client's document as it came, as a
# GraphQL::Query whose `query_string` is the client's: validation, analysis
# (complexity, depth, and Rules, which checks @defer and @stream), listeners and
# tracing see what they would without @defer. DeferDirective leaves the deferred
# fragments out of the execution, and State keeps them.
#
# Then it goes in rounds, as PHP Lighthouse's Defer: each round runs every
# fragment pending, on the object it was found on, as Plan cuts them into units
# (GraphQL::Query::Partial), all in one multiplex so the Dataloader batches across
# them, and is one payload; the fragments they hold are announced in it, and make
# the next round. A field resolves once: what the response already holds is not
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
class Lighthouse::GraphQL::Incremental::Run
  State = Lighthouse::GraphQL::Incremental::State
  Serializer = Lighthouse::GraphQL::Incremental::Serializer
  # A directive named defer or stream, as the lexer reads one (`@`, then ignored characters).
  INCREMENTAL = /@[\s,\uFEFF]*(?:defer|stream)\b/

  attr_reader :result

  # `options`: `schema.execute`'s (variables:, operation_name:, context:, ...).
  def initialize(schema, query_string, **options)
    @schema = schema
    @query_string = query_string
    @options = options
    @queue = []
    @announced = []
    @next_id = 0
    @running = []
    @round = 0
    @errors = []
    @open = {}
  end

  def start
    seconds = Lighthouse::Config.defer_max_execution_ms / 1000.0
    @deadline = clock + seconds if seconds.positive?
    @result = execute
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
  # sent. However it ends, the `on_finish` block gets the response.
  def each_payload(&block)
    emit(Serializer.initial(@result, @announced, has_next: deferred?), &block)
    until @queue.empty?
      begin
        emit(next_payload, &block)
      rescue StandardError
        emit(failure_payload, &block)
        raise
      end
    end
  ensure
    finish
  end

  # The block to call with the whole response once the last payload is out.
  def on_finish(&block)
    @finished = block
  end

  # The whole response as the client puts it together: the data of every round, the errors of
  # every round (the first pass's first), the first pass's extensions.
  def response
    first = @result.to_h
    { 'data' => @tree ? @tree.data : first['data'], 'errors' => (first['errors'].to_a + @errors).presence,
      'extensions' => first['extensions'] }.compact
  end

  private

  # graphql-ruby parses the query, once, through the schema's trace, as `schema.execute`
  # would, and answers one that does not parse. A State goes in the context of a query that
  # may use @defer or @stream (INCREMENTAL, on the text: a false positive costs an unused
  # State); it reads the document once it is parsed.
  def execute
    @state = State.new if INCREMENTAL.match?(@query_string.to_s) && traced?
    query = ::GraphQL::Query.new(@schema, @query_string, **@options.except(:context), context: query_context)
    @state&.query = query
    result = running { @schema.multiplex([query], max_complexity: nil, context: multiplex_context).first }
    return result unless @state

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
    units = plan.units(@running)
    partials = units.map { |unit| partial(unit) }
    outcome = Lighthouse::GraphQL::Incremental::Delivery.new(@state, @tree).call(units, partials, run(partials))
    @errors.concat(outcome.errors)
    found(plan, partials, outcome)
    completed = @running.map { |pending| { 'id' => pending.id, 'errors' => outcome.failed[pending] }.compact }
    Serializer.subsequent(incremental: outcome.incremental, completed: completed, extensions: outcome.extensions,
                          pending: @announced, has_next: deferred?)
  end

  # Announce the fragments the round found: Plan, and each unit's Partial, but those of a
  # fragment that failed.
  def found(plan, partials, outcome)
    @announced = []
    announce(@state.drain(plan).reject { |pending| outcome.failed.key?(pending.parent) })
    partials.each do |partial|
      found = @state.drain(partial)
      announce(found) if outcome.delivered.key?(partial)
    end
  end

  # May the fragments of this round defer the fragments they hold? Not past the limits:
  # with defer_max_nested_fields 1, the first round resolves everything left.
  def deferring?
    max = Lighthouse::Config.defer_max_nested_fields
    return false if max.positive? && @round >= max

    @deadline.nil? || clock < @deadline
  end

  def clock = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  # The Partial that runs a unit: its selections on its object, or a stream's items (a list of
  # scalars from its path, which has no selections).
  def partial(unit)
    query = @result.query
    return ::GraphQL::Query::Partial.new(object: unit.object, path: unit.path, query: query).tap { |items| place(items, unit) } if leaf_items?(unit)

    fragment = ::GraphQL::Language::Nodes::InlineFragment.new(selections: unit.stream? ? unit.owner.selections : unit.selections)
    ::GraphQL::Query::Partial.new(object: unit.object, path: unit.path, query: query, fragment_node: fragment, type: unit.type).tap { |run| place(run, unit) }
  end

  def leaf_items?(unit) = unit.stream? && unit.type.unwrap.kind.leaf?

  # A stream's Partial counts its items from 0: State puts them where they are in the list.
  def place(partial, unit)
    @state.offset(partial, unit.path, unit.owner.offset) if unit.stream?
  end

  # The responses of the partials, run in one multiplex so the Dataloader batches across them.
  # The first pass analyzed the whole document: no max_complexity again, which analysis
  # cannot apply to a Partial.
  def run(partials)
    running { @schema.multiplex(partials, context: multiplex_context, max_complexity: nil).map(&:to_h) }
  end

  # Give the fragments found their ids, and queue them. Those whose object an error nulled
  # out of the response are dropped.
  def announce(found)
    found.each do |pending|
      next unless present?(pending.path)

      pending.id = @next_id.to_s
      @next_id += 1
      @queue << pending
      @announced << pending
    end
  end

  # Does `path` lead to a value in the response's data so far?
  def present?(path) = @tree.present?(path)

  def finish
    finished = @finished
    @finished = nil
    finished&.call(response)
  end

  # Yields a payload, and keeps the ids the client was sent and has not seen completed.
  def emit(payload)
    yield payload
    payload['pending'].to_a.each { |entry| @open[entry['id']] = true }
    payload['completed'].to_a.each { |entry| @open.delete(entry['id']) }
  end

  # The last payload of a stream that failed: every id still open completes, with an error.
  def failure_payload
    errors = [{ 'message' => 'Internal server error' }]
    @errors.concat(errors)
    Serializer.subsequent(incremental: [], completed: @open.keys.map { |id| { 'id' => id, 'errors' => errors } }, pending: [], has_next: false)
  end
end
