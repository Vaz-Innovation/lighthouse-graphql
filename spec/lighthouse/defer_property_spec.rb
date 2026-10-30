# frozen_string_literal: true

# A generative spec of @defer and @stream: random queries over a small schema, each run
# streamed (Incremental::Run) and checked against the draft's invariants. Deterministic: case n
# uses seed n. DEFER_PROPERTY_CASES runs more locally (DEFER_PROPERTY_CASES=5000), and
# DEFER_PROPERTY_SEED=n runs one case.
#
# (a) the client-assembled result (data, errors by path) is the query's without @defer/@stream,
#     but for the fragments and streams completed with errors, which deliver nothing;
# (b) every id announced completes once, no id completes unannounced, hasNext is false on the
#     last payload only;
# (c) no value is delivered twice;
# (d) each field resolves once for each object and response key, but where a fragment that
#     resolved it failed: a later fragment that selects it there runs it again.
module DeferProperty
  # An object of the schema: a record (`id`) at a place of the response (`position`, the path of
  # response keys and indices to it), so a field's resolution is counted where it happens.
  Node = Struct.new(:id, :position)
  # A value graphql-ruby syncs later (Schema.lazy_resolve).
  Lazy = Struct.new(:block) do
    def value = block.call
  end

  CALLS = Hash.new(0)

  def self.count(object, context) = CALLS[[object&.position, context[:current_path].last]] += 1

  def self.child(parent, context, id, index = nil)
    Node.new(id, [*parent&.position, context[:current_path].last, *index])
  end

  def self.list(parent, context, ids) = ids.each_with_index.map { |id, index| child(parent, context, id, index) }

  # The friends of a record: two others, as Dataloader would load them.
  class Friends < GraphQL::Dataloader::Source
    def fetch(ids) = ids.map { |id| [(id % 4) + 1, ((id + 1) % 4) + 1] }
  end

  class NodeType < GraphQL::Schema::Object
    graphql_name 'Node'

    field :id, Int, null: false
    field :name, String, null: true
    field :tag, String, null: false
    field :broken, String, null: true
    field :strict, String, null: false
    field :lazy_name, String, null: true
    field :friend, NodeType, null: true
    field :friends, [NodeType], null: false
    field :maybe_friends, [NodeType, { null: true }], null: true
    field :matrix, [[Int]], null: false

    def id = DeferProperty.count(object, context) && object.id
    def name = DeferProperty.count(object, context) && "n#{object.id}"
    def tag = DeferProperty.count(object, context) && "t#{object.id}"

    def broken
      DeferProperty.count(object, context)
      object.id.even? ? raise(GraphQL::ExecutionError, "broken #{object.id}") : "b#{object.id}"
    end

    # Always null: a non-null field that fails, wherever it is (so every object a fragment is
    # deferred on fails it alike, and the query without the fragment is what the client gets).
    def strict = DeferProperty.count(object, context) && nil

    def lazy_name
      DeferProperty.count(object, context)
      Lazy.new(-> { "l#{object.id}" })
    end

    def friend = DeferProperty.count(object, context) && DeferProperty.child(object, context, (object.id % 4) + 1)

    def friends
      DeferProperty.count(object, context)
      DeferProperty.list(object, context, dataloader.with(Friends).load(object.id))
    end

    def maybe_friends
      DeferProperty.count(object, context)
      [DeferProperty.child(object, context, (object.id % 4) + 1, 0), nil]
    end

    def matrix = DeferProperty.count(object, context) && [[object.id, 1], [object.id, 2], [object.id, 3]]
  end

  class QueryType < GraphQL::Schema::Object
    graphql_name 'Query'

    field :node, NodeType, null: true do
      argument :id, Int
    end
    field :nodes, [NodeType], null: false
    field :numbers, [Int], null: false

    def node(id:) = DeferProperty.count(nil, context) && DeferProperty.child(nil, context, id)
    def nodes = DeferProperty.count(nil, context) && DeferProperty.list(nil, context, [1, 2, 3, 4])
    def numbers = DeferProperty.count(nil, context) && [1, 2, 3, 4, 5]
  end

  class Schema < GraphQL::Schema
    query QueryType
    use GraphQL::Dataloader
    lazy_resolve Lazy, :value
    use Lighthouse::GraphQL::Defer
  end

  def self.seeds
    return [Integer(ENV['DEFER_PROPERTY_SEED'])] if ENV['DEFER_PROPERTY_SEED']

    (1..Integer(ENV.fetch('DEFER_PROPERTY_CASES', '300'))).to_a
  end

  # What is wrong with the case of `seed`, or nil.
  def self.check(seed)
    generator = Generator.new(seed).query
    query = generator.print
    client = Client.new(payloads(query, generator.variables)).assemble
    problems = client.problems + twice(client)
    problems += compare(client, plain(generator, client.failed))
    "seed #{seed}: #{problems.uniq.join('; ')}\n#{query}\nvariables: #{generator.variables}" unless problems.empty?
  rescue StandardError => e
    "seed #{seed}: #{e.class}: #{e.message}\n#{e.backtrace.first(3).join("\n")}"
  end

  def self.payloads(query, variables)
    CALLS.clear
    [].tap { |all| Lighthouse::GraphQL::Incremental::Run.new(Schema, query, variables: variables).start.each_payload { |payload| all << payload } }
  end

  # The response to the query without @defer and @stream, nor the fragments of the labels `failed`.
  def self.plain(generator, failed) = Schema.execute(generator.print(plain: true, without: failed), variables: generator.variables).to_h

  # (a)
  def self.compare(client, plain)
    problems = []
    problems << "data differs: got #{client.data.inspect[0, 300]}, want #{plain['data'].inspect[0, 300]}" unless client.data == plain['data']
    got = errors_by_path(client.errors, client.data)
    want = errors_by_path(plain['errors'].to_a, plain['data'])
    problems << "errors differ: extra #{(got - want).first(3)}, missing #{(want - got).first(3)}" unless got == want
    problems
  end

  # The errors, by path, of the fields whose parent the final data holds: a field under an object
  # an error nulled out may or may not have run, deferred or not.
  def self.errors_by_path(errors, data)
    errors.select { |error| error['path'].nil? || !Lighthouse::GraphQL::Incremental::Tree.at(data, error['path'][0...-1]).nil? }
          .map { |error| [error['path'], error['message']] }.sort_by(&:inspect)
  end

  # (d) A field resolves once, but where a fragment that resolved it failed, sending none of its
  # data: a later fragment that selects it there resolves it again.
  def self.twice(client)
    twice = CALLS.select { |(position, _), count| count > 1 + client.failed_paths.count { |path| position.to_a.first(path.size) == path } }
    twice.empty? ? [] : ["resolved twice: #{twice.keys.first(3).inspect}"]
  end

  # A query, as a tree that prints with its directives, or without @defer and @stream (and
  # without the fragments of some labels).
  Field = Struct.new(:name, :args, :key, :selections, :stream, :gate, keyword_init: true)
  Fragment = Struct.new(:selections, :defer, :gate, :spread, keyword_init: true)

  # Builds a random query (and its named fragments) from a seed.
  class Generator
    LEAVES = %w[name tag broken lazyName].freeze
    # The alias a field sometimes goes by: always the same, so two fields of one key never differ.
    ALIASES = { 'name' => 'nick', 'friend' => 'pal', 'friends' => 'pals' }.freeze

    attr_reader :variables

    def initialize(seed)
      @random = Random.new(seed)
      @labels = 0
      @variables = {}
      @definitions = {}
    end

    def query
      2.times { |index| @definitions["F#{index}"] = selections(1, streamed: true) if chance(0.5) }
      @root = root
      self
    end

    # Only the variables and fragments the text uses are declared (a document must use them all).
    def print(plain: false, without: [])
      @plain = plain
      @without = without
      operation = " { #{body(@root)} }"
      definitions = @definitions.to_h { |name, selections| [name, "fragment #{name} on Node { #{body(selections)} }"] }
      used = definitions.keys.select { |name| reaches?(name, operation, definitions) }
      text = ([operation] + used.map { |name| definitions[name] }).join("\n")
      declared = @variables.keys.select { |name| text.match?(/\$#{name}\b/) }.map { |name| "$#{name}: Boolean!" }
      (declared.empty? ? 'query' : "query(#{declared.join(', ')})") + text
    end

    def reaches?(name, operation, definitions)
      return true if operation.match?(/\.\.\.#{name}\b/)

      definitions.any? { |other, text| other != name && text.match?(/\.\.\.#{name}\b/) && reaches?(other, operation, definitions) }
    end

    private

    def chance(probability) = @random.rand < probability
    def pick(list) = list[@random.rand(list.size)]

    def root
      fields = [Field.new(name: 'node', args: { id: 1 }, key: 'n1', selections: selections(2))]
      fields << Field.new(name: 'node', args: { id: 3 }, key: 'n3', selections: selections(2)) if chance(0.5)
      fields << Field.new(name: 'nodes', selections: selections(1, streamed: true), stream: stream) if chance(0.6)
      fields << Field.new(name: 'numbers', stream: stream) if chance(0.3)
      fields << fragment(1) { root_fields } if chance(0.4)
      fields
    end

    def root_fields
      [Field.new(name: 'node', args: { id: pick([1, 2]) }, key: nil, selections: selections(2))].each { |field| field.key = "n#{field.args[:id]}" }
    end

    # The selections of a Node, `deferred` inside a deferred fragment: the failing non-null field
    # only goes there (the fragment then fails, and delivers nothing). Outside one it could fail
    # the items of a stream (a list two declarations merge may stream), which the client keeps
    # the first of, where the response without @stream nulls the list.
    def selections(depth, streamed: false, deferred: false)
      list = [Field.new(name: 'id')]
      @random.rand(1..3).times { list << leaf(deferred) }
      list.concat(objects(depth, streamed, deferred) + fragments(depth, streamed, deferred)) if depth.positive?
      list << spread if !@definitions.empty? && chance(0.4)
      list.uniq { |selection| selection.is_a?(Field) ? selection.key || selection.name : selection.object_id }
    end

    def fragments(depth, streamed, deferred)
      [0.5, 0.3].select { |probability| chance(probability) }.map do
        fragment(depth) { |defers| selections(depth - 1, streamed: streamed, deferred: deferred || defers) }
      end
    end

    def leaf(deferred)
      field = named(pick(deferred ? LEAVES + %w[strict] : LEAVES))
      field.gate = gate if chance(0.15)
      field
    end

    def named(name, **options) = Field.new(name: name, key: (ALIASES[name] if chance(0.2)), **options)

    def objects(depth, streamed, deferred)
      list = []
      list << named('friend', selections: selections(depth - 1, streamed: streamed, deferred: deferred)) if chance(0.5)
      if chance(0.5)
        streams = stream
        list << named('friends', selections: selections(depth - 1, streamed: streamed || !streams.nil?, deferred: false), stream: streams)
      end
      list << Field.new(name: 'maybeFriends', selections: selections(depth - 1, streamed: true), stream: stream) if chance(0.3)
      list << Field.new(name: 'matrix', stream: stream) if chance(0.3)
      list
    end

    def stream
      return nil unless chance(0.4)

      { initial: pick([0, 1, 2, 5]), label: label }
    end

    # The block gets whether the fragment is deferred.
    def fragment(_depth)
      defer = chance(0.85) ? { label: label, if: condition } : nil
      Fragment.new(selections: yield(defers?(defer)), defer: defer, gate: (gate if chance(0.15)))
    end

    def defers?(defer)
      condition = defer&.dig(:if)
      condition == true || (condition.is_a?(String) && @variables[condition.delete_prefix('$')])
    end

    def spread
      Fragment.new(spread: pick(@definitions.keys), defer: ({ label: label, if: true } if chance(0.6)), gate: (gate if chance(0.1)))
    end

    def gate = { pick(%w[skip include]) => (chance(0.3) ? variable : chance(0.5)) }

    # A defer's `if`: mostly true, sometimes false or a variable.
    def condition
      roll = @random.rand
      return true if roll < 0.6
      return false if roll < 0.8

      variable
    end

    def variable
      name = "v#{@variables.size}"
      @variables[name] = chance(0.5)
      "$#{name}"
    end

    def label = "L#{@labels += 1}"

    def body(selections) = selections.filter_map { |selection| node(selection) }.join(' ')

    def node(selection)
      selection.is_a?(Field) ? field(selection) : fragment_text(selection)
    end

    def field(field)
      text = field.key ? "#{field.key}: #{field.name}" : field.name.dup
      text << arguments(field.args) if field.args
      text << directive('stream', initialCount: field.stream[:initial], label: field.stream[:label].inspect) if field.stream && !@plain
      text << gate_text(field.gate)
      text << " { #{body(field.selections)} }" if field.selections
      text
    end

    def fragment_text(fragment)
      return nil if fragment.defer && @without.include?(fragment.defer[:label])

      text = fragment.spread ? "...#{fragment.spread}" : +'...'
      text << directive('defer', label: fragment.defer[:label].inspect, if: fragment.defer[:if]) if fragment.defer && !@plain
      text << gate_text(fragment.gate)
      text << " { #{body(fragment.selections)} }" unless fragment.spread
      text
    end

    def arguments(args) = "(#{args.map { |name, value| "#{name}: #{value}" }.join(', ')})"

    def directive(name, **arguments) = " @#{name}(#{arguments.map { |key, value| "#{key}: #{value}" }.join(', ')})"

    def gate_text(gate)
      return '' unless gate

      gate.map { |name, value| " @#{name}(if: #{value})" }.join
    end
  end

  # The response the client puts together from the payloads, checking (b) and (c) on the way.
  class Client
    attr_reader :data, :errors, :failed, :failed_paths, :problems

    def initialize(payloads)
      @payloads = payloads
      @problems = []
      @labels = {}
      @failed = []
      @failed_paths = []
      @errors = []
    end

    def assemble
      first = @payloads.first
      @data = first['data'].deep_dup
      @errors.concat(first['errors'].to_a)
      @pending = {}
      @completed = Hash.new(0)
      @payloads.each_with_index { |payload, index| read(payload, index) }
      @pending.each_key { |id| problem("id #{id} completed #{@completed[id]} times") unless @completed[id] == 1 }
      self
    end

    private

    # (b) and (c), as each payload comes.
    def read(payload, index)
      problem("hasNext #{payload['hasNext']} on payload #{index} of #{@payloads.size}") if payload['hasNext'] != (index < @payloads.size - 1)
      payload['pending'].to_a.each do |entry|
        problem("id #{entry['id']} announced twice") if @pending.key?(entry['id'])
        @pending[entry['id']] = entry
      end
      payload['incremental'].to_a.each { |entry| apply(entry, @pending) }
      payload['completed'].to_a.each { |entry| complete(entry) }
    end

    def complete(entry)
      announced = @pending[entry['id']]
      problem("id #{entry['id']} completed but never announced") unless announced
      @completed[entry['id']] += 1
      return unless entry['errors'] && announced

      @failed << announced['label']
      @failed_paths << announced['path']
    end

    def problem(text) = @problems << text

    def apply(entry, pending)
      announced = pending[entry['id']] or return problem("entry for unannounced id #{entry['id']}")
      path = announced['path'] + entry['subPath'].to_a
      target = path.reduce(@data) { |value, key| value.is_a?(Hash) || value.is_a?(Array) ? value[key] : nil }
      return problem("entry at #{path.inspect}, which holds nothing") if target.nil?

      @errors.concat(entry['errors'].to_a)
      entry.key?('items') ? target.concat(entry['items'].deep_dup) : merge(target, entry['data'], path)
    end

    # (c): a key the client holds already is a value delivered twice.
    def merge(target, data, path)
      data.each do |key, value|
        if target.key?(key) && !(target[key].is_a?(Hash) && value.is_a?(Hash))
          problem("#{(path + [key]).inspect} delivered twice")
        elsif target[key].is_a?(Hash)
          merge(target[key], value, path + [key])
        else
          target[key] = value.deep_dup
        end
      end
    end
  end
end

RSpec.describe 'Deferring fields, generated' do
  seeds = DeferProperty.seeds

  it "keeps the draft's invariants over #{seeds.size} random queries" do
    failures = DeferProperty.seeds.filter_map { |seed| DeferProperty.check(seed) }

    expect(failures).to be_empty, -> { "#{failures.size} of #{DeferProperty.seeds.size} cases failed:\n\n#{failures.first(5).join("\n\n")}" }
  end
end
