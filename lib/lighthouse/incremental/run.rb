# frozen_string_literal: true

require 'active_support/core_ext/object/deep_dup'

# One operation, run in as many passes as @defer asks for.
#
#   run = Lighthouse::GraphQL::Incremental::Run.new(schema, query, variables: {}, context: {}, stream: true).start
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
# With `stream: false` nothing is deferred: the query is checked and answered at
# once, as the specification allows a server that does not stream.
class Lighthouse::GraphQL::Incremental::Run
  State = Lighthouse::GraphQL::Incremental::State
  Serializer = Lighthouse::GraphQL::Incremental::Serializer
  # A directive named defer or stream, as the lexer reads one (`@`, then ignored characters).
  INCREMENTAL = /@[\s,\uFEFF]*(?:defer|stream)\b/

  attr_reader :result

  # `options`: `schema.execute`'s (variables:, operation_name:, context:, ...).
  def initialize(schema, query_string, stream: true, **options)
    @schema = schema
    @query_string = query_string
    @stream = stream
    @options = options
    @queue = []
    @announced = []
    @next_id = 0
    @running = []
    @round = 0
    @errors = []
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

  # The initial payload, then each later one, until `hasNext` is false. A round that fails
  # ends the stream with a last payload, which completes, with an error, the ids the client
  # was sent and has not seen completed, then raises again. However it ends, the `on_finish`
  # block gets the response.
  def each_payload
    yield Serializer.initial(@result, @announced, has_next: deferred?)
    until @queue.empty?
      begin
        payload = next_payload
      rescue StandardError
        yield failure_payload
        raise
      end
      yield payload
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
    { 'data' => @tree, 'errors' => (first['errors'].to_a + @errors).presence, 'extensions' => first['extensions'] }.compact
  end

  private

  # graphql-ruby parses the query, once, through the schema's trace, as `schema.execute`
  # would, and answers one that does not parse. A State goes in the context of a query that
  # may use @defer or @stream (INCREMENTAL, on the text: a false positive costs an unused
  # State); it reads the document once it is parsed.
  def execute
    @state = State.new if @stream && INCREMENTAL.match?(@query_string.to_s)
    query = ::GraphQL::Query.new(@schema, @query_string, **@options.except(:context), context: query_context)
    @state&.query = query
    result = @schema.multiplex([query], max_complexity: nil, context: multiplex_context).first
    return result unless @state

    @tree = result.to_h['data'].deep_dup
    announce(@state.drain(query))
    result
  end

  # The app's context, as it gave it; with the State, a copy of it, so that its Hash is left
  # as it was.
  def query_context
    context = @options[:context]
    @state ? (context || {}).merge(State::CONTEXT_KEY => @state) : context
  end

  # What Schema.execute hands its multiplex of the query's context, and the trace mode with
  # Recorder when the response streams, unless the app picked one: a new Hash each time, where
  # graphql-ruby puts the multiplex's dataloader and trace, so each round gets its own.
  def multiplex_context
    context = @options[:context] || {}
    mode = context[:trace_mode] || (Lighthouse::GraphQL::Incremental::Recorder::MODE if @state && @schema.default_trace_mode == :default)
    { backtrace: context[:backtrace], tracers: context[:tracers], trace: context[:trace], dataloader: context[:dataloader], trace_mode: mode }
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
    payload = deliver(units, partials, run(partials))
    found(plan, partials)
    Serializer.subsequent(**payload, pending: @announced, has_next: deferred?).tap { @running = [] }
  end

  # Announce the fragments the round found: Plan, and each unit's Partial.
  def found(plan, partials)
    @announced = []
    announce(@state.drain(plan))
    partials.each { |partial| announce(@state.drain(partial)) }
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
    @schema.multiplex(partials, context: multiplex_context, max_complexity: nil).map(&:to_h)
  end

  # The payload's `incremental`, `completed` and `extensions` for the units' responses, which
  # go in the response's data so far.
  def deliver(units, partials, results)
    incremental = []
    extensions = {}
    failed = {}.compare_by_identity
    units.each_with_index do |unit, index|
      entry = entry(unit, partials[index], results[index])
      next incremental << entry if entry.key?('data') || entry.key?('items')

      unit.pendings.each { |pending| failed[pending] = failed.fetch(pending, []) + entry['errors'].to_a }
      extensions.merge!(entry['extensions'].to_h)
    end
    { incremental: incremental.reject { |entry| empty?(entry) }, completed: completed(failed), extensions: extensions }
  end

  # Each fragment and list of the round is complete, with the errors of a unit that left no data.
  def completed(failed)
    @running.map { |pending| { 'id' => pending.id, 'errors' => failed[pending] }.compact }
  end

  # A unit's incremental entry (a stream's `items`, data below its fragment's path at its
  # `subPath`), with the errors and the extensions of its run (BuildExtensionsResponse,
  # ManipulateResult); with no data (a non-null field failed beyond the unit), its errors only.
  def entry(unit, partial, response)
    data, errors, extensions = response.values_at('data', 'errors', 'extensions')
    absolute_errors(errors, partial) if unit.stream?
    @errors.concat(errors.to_a)
    return { 'errors' => errors, 'extensions' => extensions } if data.nil?

    merge(unit, data.deep_dup)
    sub_path = unit.sub_path unless unit.stream? || unit.sub_path.empty?
    { 'id' => unit.owner.id, 'subPath' => sub_path, (unit.stream? ? 'items' : 'data') => data, 'errors' => errors,
      'extensions' => extensions }.compact
  end

  def empty?(entry) = entry.size == 2 && (entry['data'] || entry['items']).empty?

  # The response's data so far, with (a copy of) a unit's: a stream's items after the list's, a
  # fragment's fields in its object.
  def merge(unit, data)
    target = State.at(@tree, unit.path)
    unit.stream? ? target&.concat(data) : deep_merge(target, data)
  end

  def deep_merge(target, data)
    return unless target.is_a?(Hash)

    data.each { |key, value| target[key].is_a?(Hash) && value.is_a?(Hash) ? deep_merge(target[key], value) : target[key] = value }
  end

  # The paths of a stream's errors, as the response's.
  def absolute_errors(errors, partial)
    errors&.each { |error| error['path'] = @state.absolute(partial, error['path']) if error['path'] }
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
  def present?(path) = !State.at(@tree, path).nil?

  def finish
    finished = @finished
    @finished = nil
    finished&.call(response)
  end

  # The round that failed: its fragments were announced in an earlier payload. Those it
  # found itself (queued) were never sent, and are not completed.
  def failure_payload
    errors = [{ 'message' => 'Internal server error' }]
    @errors.concat(errors)
    Serializer.subsequent(incremental: [], completed: @running.map do |pending|
      { 'id' => pending.id, 'errors' => errors }
    end, pending: [], has_next: false)
  end
end
