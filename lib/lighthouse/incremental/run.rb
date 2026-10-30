# frozen_string_literal: true

# One operation, run in as many passes as @defer asks for.
#
#   run = Lighthouse::GraphQL::Incremental::Run.new(schema, query, variables: {}, context: {}, stream: true).start
#   run.result                   # the first pass, as `schema.execute` answers it
#   run.deferred?                # fragments are pending
#   run.each_payload { |payload| ... }   # the initial payload, then one per deferred fragment
#
# `start` parses the query, has Document check and stamp its @defer, and runs
# the first pass on the stamped document: the whole document goes through
# graphql-ruby's validation and analysis (complexity, depth) once, as it would
# without @defer, and DeferDirective leaves the deferred fragments out of the
# execution. Each pending fragment is then run on the object it was found on
# (GraphQL::Query#run_partials), the fragments of one kind together in one
# multiplex so the Dataloader batches across the objects of a list. A field's
# resolver stack, @throttle and @cache among them, runs once, in the pass that
# resolves the field; a mutation does not run again.
#
# With `stream: false` nothing is deferred: the query is checked and answered at
# once, as the specification allows a server that does not stream.
class Lighthouse::GraphQL::Incremental::Run
  State = Lighthouse::GraphQL::Incremental::State
  Serializer = Lighthouse::GraphQL::Incremental::Serializer

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
  end

  def start
    @result = execute
    self
  end

  # Fragments are pending: the response goes in more than one payload.
  def deferred?
    !@queue.empty?
  end

  # The initial payload, then each later one, until `hasNext` is false.
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
  end

  private

  def execute
    document = parse
    return @schema.execute(@query_string, **@options) unless document

    prepared = Lighthouse::GraphQL::Incremental::Document.prepare(@schema, document)
    return { 'errors' => prepared.errors.map(&:to_h) } unless prepared.errors.empty?
    return @schema.execute(@query_string, **@options) unless @stream && !prepared.fragments.empty?

    @state = State.new(prepared.fragments)
    context = (@options[:context] || {}).merge(State::CONTEXT_KEY => @state)
    result = @schema.execute(document: prepared.document, **@options, context: context)
    announce(@state.drain, result.to_h['data'], [])
    result
  end

  def parse
    ::GraphQL.parse(@query_string, max_tokens: @schema.max_query_string_tokens)
  rescue ::GraphQL::ParseError
    nil
  end

  # Runs the first pending fragment on all the objects it waits on.
  def next_payload
    fragment = @queue.first.fragment
    group = @queue.select { |pending| pending.fragment.equal?(fragment) }
    @queue -= group
    @running = group
    results = run_fragment(fragment, group)
    @announced = []
    incremental = []
    completed = []
    group.zip(results) do |pending, response|
      deliver(pending, response, incremental, completed)
      announce(@state.drain, response['data'], pending.path, pending.offset.to_i)
    end
    Serializer.subsequent(incremental: incremental, completed: completed, pending: @announced, has_next: deferred?)
  end

  # The responses of `fragment` run on each object of `group` (the items of a stream), in one
  # multiplex so the Dataloader batches across them.
  def run_fragment(fragment, group)
    query = @result.query
    type = query.types.type(fragment.type_name) unless fragment.stream
    partials = group.map do |pending|
      options = fragment.stream ? {} : { fragment_node: fragment.node, type: type }
      ::GraphQL::Query::Partial.new(object: pending.object, path: pending.path, query: query, **options)
    end
    # The first pass analyzed the whole document: no max_complexity again, which analysis
    # cannot apply to a Partial.
    @schema.multiplex(partials, context: query.context, max_complexity: nil).map(&:to_h)
  end

  # A fragment's data goes in `incremental` (a stream's as `items`); a null data (a
  # non-null field failed beyond the fragment) leaves only its errors, in `completed`.
  def deliver(pending, response, incremental, completed)
    data = response['data']
    errors = response['errors']
    offset_errors(errors, pending) if pending.fragment.stream
    if data.nil?
      completed << { 'id' => pending.id, 'errors' => errors }.compact
    else
      key = pending.fragment.stream ? 'items' : 'data'
      incremental << { 'id' => pending.id, key => data, 'errors' => errors }.compact unless data.empty? && errors.nil?
      completed << { 'id' => pending.id }
    end
  end

  # The paths of a stream's errors count its items from the first one run, the response's from the first.
  def offset_errors(errors, pending)
    errors&.each do |error|
      path = error['path']
      path[pending.path.size] += pending.offset if path && path[pending.path.size].is_a?(Integer)
    end
  end

  # Give the fragments found since the last call their ids, and queue them. Those
  # whose object an error nulled out of `data` (found from `base`) are dropped. `offset`:
  # the index in the response's list of the first item of `data`, when it is a stream's.
  def announce(found, data, base, offset = 0)
    found.each do |pending|
      next unless present?(data, pending.path.drop(base.size))

      pending.path = pending.path.dup.tap { |path| path[base.size] += offset } if offset.positive? && pending.path[base.size].is_a?(Integer)

      pending.id = @next_id.to_s
      @next_id += 1
      @queue << pending
      @announced << pending
    end
  end

  # Does `path` lead to a value in `data`?
  def present?(data, path)
    path.each do |key|
      data = data.is_a?(Array) || data.is_a?(Hash) ? data[key] : nil
      return false if data.nil?
    end
    !data.nil?
  end

  def failure_payload
    errors = [{ 'message' => 'Internal server error' }]
    Serializer.subsequent(
      incremental: [], completed: (@running.to_a + @queue).map { |pending| { 'id' => pending.id, 'errors' => errors } }, pending: [], has_next: false
    )
  end
end
