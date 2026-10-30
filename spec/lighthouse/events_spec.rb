# frozen_string_literal: true

require 'tmpdir'

# A namespace the RegisterDirectiveNamespaces listener points at.
module EventsSpecDirectives
  class StartsWith < Lighthouse::GraphQL::Directives::Arguments::Base
    def self.directive_name = 'startsWith'
    def self.definition = 'directive @startsWith(key: String) on ARGUMENT_DEFINITION'

    def handle_builder(relation, value)
      relation.where(arel_column(relation).matches("#{value}%"))
    end
  end

  NOT_A_DIRECTIVE = 1
end

RSpec.describe Lighthouse::Events do
  let(:events) { described_class }
  let(:sdl) { 'type Query { widgets: [Widget!]! @all } type Widget { id: ID! name: String }' }

  # Every event the listener hears, by class name.
  def record(event_class = Lighthouse::Events::Event)
    [].tap { |seen| events.listen(event_class) { |event| (seen << event) && nil } }
  end

  describe 'the dispatcher' do
    let(:event_class) { Class.new(Lighthouse::Events::Event) }

    it 'calls the listeners of the event, its superclasses and Event, in registration order, and returns their non-nil values' do
      calls = []
      events.listen(event_class) { |_| (calls << :own) && :a }
      events.listen(Lighthouse::Events::Event) { |_| (calls << :base) && nil }
      events.listen(Class.new(Lighthouse::Events::Event)) { |_| calls << :other }
      events.listen(Lighthouse::Events::Event, ->(_) { (calls << :lambda) && :b })

      expect(events.dispatch(event_class.new)).to eq(%i[a b])
      expect(calls).to eq(%i[own base lambda])
    end

    it 'does not call the listeners of a subclass for a superclass event' do
      base = Class.new(Lighthouse::Events::Event)
      sub = Class.new(base)
      heard = []
      events.listen(sub) { |event| heard << event }

      events.dispatch(base.new)
      expect(heard).to be_empty
      events.dispatch(sub.new)
      expect(heard.size).to eq(1)
    end

    it 'forgets a listener, and reset! forgets all of them' do
      listener = events.listen(event_class) { :heard }
      expect(events.dispatch(event_class.new)).to eq([:heard])

      events.forget(listener)
      expect(events.dispatch(event_class.new)).to eq([])

      events.listen(event_class) { :again }
      events.reset!
      expect(events.dispatch(event_class.new)).to eq([])
    end

    it 'needs something to call' do
      expect { events.listen(event_class) }.to raise_error(ArgumentError)
    end

    it 'tells whether anyone listens' do
      expect(events.listening?(event_class)).to be(false)
      events.listen(Lighthouse::Events::Event) { nil }
      expect(events.listening?(event_class)).to be(true)
    end

    it 'instruments every dispatch through ActiveSupport::Notifications' do
      payloads = []
      subscription = ActiveSupport::Notifications.subscribe('start_execution.lighthouse') { |*, payload| payloads << payload }
      event = Lighthouse::Events::StartExecution.new(nil, nil, {}, nil, {})
      events.dispatch(event)

      expect(payloads).to eq([{ event: event }])
      expect(events.notification_name(Lighthouse::Events::StartExecution)).to eq('start_execution.lighthouse')
    ensure
      ActiveSupport::Notifications.unsubscribe(subscription)
    end

    it 'runs the execution events for notification subscribers alone' do
      schema = build_schema(sdl)
      names = []
      subscription = ActiveSupport::Notifications.subscribe(/\.lighthouse\z/) { |name, *| names << name }
      schema.execute('{ widgets { id } }')

      expect(names).to eq(%w[start_execution.lighthouse build_extensions_response.lighthouse
                             manipulate_result.lighthouse end_execution.lighthouse])
    ensure
      ActiveSupport::Notifications.unsubscribe(subscription)
    end
  end

  describe 'the schema build' do
    it 'BuildSchemaString appends the SDL its listeners return' do
      seen = nil
      events.listen(Lighthouse::Events::BuildSchemaString) do |event|
        seen = event.user_schema
        'extend type Query { version: String @field(resolver: "EventsSpecVersion") }'
      end
      stub_const('EventsSpecVersion', Class.new { def self.call(*) = '1.2' })

      schema = build_schema(sdl)

      expect(seen).to eq(sdl)
      expect(schema.execute('{ version }').to_h).to eq('data' => { 'version' => '1.2' })
    end

    it 'RegisterDirectiveNamespaces registers the directives of a module, a name, or an Array of them' do
      events.listen(Lighthouse::Events::RegisterDirectiveNamespaces) { %w[EventsSpecDirectives] }
      Widget.create!(name: 'alpha')
      Widget.create!(name: 'beta')

      schema = build_schema('type Query { widgets(name: String @startsWith): [Widget!]! @all } type Widget { name: String }')

      expect(Lighthouse::DirectiveRegistry.default.arg_builder_class('startsWith')).to eq(EventsSpecDirectives::StartsWith)
      expect(schema.execute('{ widgets(name: "al") { name } }').to_h).to eq('data' => { 'widgets' => [{ 'name' => 'alpha' }] })
    ensure
      Lighthouse::DirectiveRegistry.instance_variable_set(:@default, nil)
    end

    it 'RegisterDirectiveNamespaces takes a Module, and rejects an unknown namespace' do
      listener = events.listen(Lighthouse::Events::RegisterDirectiveNamespaces) { [EventsSpecDirectives] }
      build_schema(sdl)
      expect(Lighthouse::DirectiveRegistry.default.arg_builder_class('startsWith')).to eq(EventsSpecDirectives::StartsWith)

      events.forget(listener)
      events.listen(Lighthouse::Events::RegisterDirectiveNamespaces) { 'NoSuchNamespace' }
      expect { build_schema(sdl) }.to raise_error(Lighthouse::DefinitionError, /NoSuchNamespace/)
    ensure
      Lighthouse::DirectiveRegistry.instance_variable_set(:@default, nil)
    end

    it 'ManipulateAST builds the schema from the document its listeners leave' do
      events.listen(Lighthouse::Events::ManipulateAST) do |event|
        sdl = "#{event.document_ast.to_query_string}\nextend type Query { extra: Int @field(resolver: \"EventsSpecExtra\") }"
        event.document_ast = GraphQL.parse(sdl)
        nil
      end
      stub_const('EventsSpecExtra', Class.new { def self.call(*) = 7 })

      schema = build_schema('type Query { hi: String }')

      expect(schema.execute('{ extra }').to_h).to eq('data' => { 'extra' => 7 })
    end

    it 'dispatches the build events in order, before the schema is built' do
      seen = record
      build_schema(sdl)

      expect(seen.map { |event| event.class.name.demodulize }).to eq(%w[RegisterDirectiveNamespaces BuildSchemaString ManipulateAST])
    end

    describe 'with the schema cache' do
      let(:dir) { Dir.mktmpdir }

      before { Lighthouse.configure { |config| config.schema_cache_path = dir } }

      after { FileUtils.remove_entry(dir) }

      it 'fires BuildSchemaString and ManipulateAST on a cache miss only, and caches what the listeners made' do
        Lighthouse.configure { |config| config.schema_cache = true }
        builds = 0
        events.listen(Lighthouse::Events::BuildSchemaString) { (builds += 1) && 'extend type Query { cached: Int }' }
        registered = 0
        events.listen(Lighthouse::Events::RegisterDirectiveNamespaces) { registered += 1 and nil }
        ast = 0
        events.listen(Lighthouse::Events::ManipulateAST) { ast += 1 and nil }

        first = build_schema(sdl)
        second = build_schema(sdl)

        expect([builds, ast, registered]).to eq([1, 1, 2])
        expect(first.get_field('Query', 'cached')).not_to be_nil
        expect(second.get_field('Query', 'cached')).not_to be_nil
      end
    end
  end

  describe 'execution' do
    let(:schema) { build_schema(sdl) }

    before { Widget.create!(name: 'w') }

    it 'dispatches StartExecution, BuildExtensionsResponse, ManipulateResult and EndExecution in order' do
      order = []
      %i[StartExecution BuildExtensionsResponse ManipulateResult EndExecution].each do |name|
        events.listen(described_class.const_get(name)) { |_| order << name }
      end

      schema.execute('{ widgets { id } }')

      expect(order).to eq(%i[StartExecution BuildExtensionsResponse ManipulateResult EndExecution])
    end

    it 'gives StartExecution the schema, the parsed query, variables, operation name and context' do
      seen = record(Lighthouse::Events::StartExecution).tap { nil }
      schema.execute('query Q($n: Int) { widgets { id } }', variables: { 'n' => 1 }, operation_name: 'Q', context: { user: 1 })

      event = seen.first
      expect(event.schema).to eq(schema)
      expect(event.query).to be_a(GraphQL::Language::Nodes::Document)
      expect([event.variables, event.operation_name, event.context[:user]]).to eq([{ 'n' => 1 }, 'Q', 1])
      expect(event.moment).to be_a(Time)
    end

    it 'fires StartExecution per operation of a multiplex' do
      seen = record(Lighthouse::Events::StartExecution)
      schema.multiplex([{ query: '{ widgets { id } }' }, { query: '{ widgets { name } }' }])

      expect(seen.size).to eq(2)
    end

    it 'gives EndExecution the operation that ran, which pairs it with its StartExecution in a batch (#4)' do
      started = record(Lighthouse::Events::StartExecution)
      ended = record(Lighthouse::Events::EndExecution)
      schema.multiplex([{ query: 'query Mine { widgets { id } }', context: { user: 1 } },
                        { query: 'query Everyone { nope }' }, { query: '{ widgets { name } }' }])

      expect(ended.map { |event| [event.operation_name, event.result.key?('errors')] }).to eq([['Mine', false], ['Everyone', true], [nil, false]])
      expect(ended.first.context[:user]).to eq(1)
      expect(started.map(&:graphql_query)).to eq(ended.map(&:graphql_query))
      expect(started.map { |event| event.graphql_query.selected_operation_name }).to eq(['Mine', 'Everyone', nil])
    end

    it 'merges the ExtensionsResponses of BuildExtensionsResponse into the result' do
      events.listen(Lighthouse::Events::BuildExtensionsResponse) do |event|
        Lighthouse::Events::ExtensionsResponse.new(:widgets_seen, event.result['data']['widgets'].size)
      end
      events.listen(Lighthouse::Events::BuildExtensionsResponse) do |_|
        [Lighthouse::Events::ExtensionsResponse.new('tag', { 'a' => 1 }), 'ignored']
      end

      result = schema.execute('{ widgets { id } }').to_h

      expect(result['extensions']).to eq('widgets_seen' => 1, 'tag' => { 'a' => 1 })
      expect(result['data']['widgets'].size).to eq(1)
    end

    it 'adds no extensions when no listener answers one' do
      events.listen(Lighthouse::Events::BuildExtensionsResponse) { nil }

      expect(schema.execute('{ widgets { id } }').to_h).not_to have_key('extensions')
    end

    it 'lets ManipulateResult change the result in place, or replace it' do
      events.listen(Lighthouse::Events::ManipulateResult) { |event| event.result['data']['widgets'].first['name'] = 'changed' }
      end_results = []
      events.listen(Lighthouse::Events::EndExecution) { |event| end_results << event.result }

      result = schema.execute('{ widgets { id name } }').to_h

      expect(result['data']['widgets'].first['name']).to eq('changed')
      expect(end_results.first).to eq(result)

      events.reset!
      events.listen(Lighthouse::Events::ManipulateResult) { |event| event.result = { 'data' => { 'replaced' => true } } }
      expect(schema.execute('{ widgets { id } }').to_h).to eq('data' => { 'replaced' => true })
    end

    it 'dispatches for a query that fails validation' do
      results = []
      events.listen(Lighthouse::Events::EndExecution) { |event| results << event.result }

      schema.execute('{ nope }')

      expect(results.first['errors'].first['message']).to include('nope')
    end

    it 'leaves the result alone when nothing listens' do
      expect(schema.execute('{ widgets { id } }').to_h.keys).to eq(['data'])
    end
  end

  describe 'operations' do
    let!(:schema) { build_schema(sdl) }

    it 'PersistedQueries.execute dispatches the operation going in and the result coming out' do
      seen = record

      result = Lighthouse::GraphQL::PersistedQueries.execute(schema, query: '{ widgets { id } }', variables: { 'a' => 1 }, operation_name: nil)

      start = seen.first
      expect(start).to be_a(Lighthouse::Events::StartOperationOrOperations)
      expect(start.operation_or_operations).to eq(query: '{ widgets { id } }', variables: { 'a' => 1 }, operation_name: nil, extensions: nil)
      expect(seen.last).to be_a(Lighthouse::Events::EndOperationOrOperations)
      expect(seen.last.result_or_results).to equal(result)
    end

    it 'ends the operation with the error of a persisted-query protocol failure' do
      seen = record(Lighthouse::Events::EndOperationOrOperations)
      extensions = { 'persistedQuery' => { 'version' => 1, 'sha256Hash' => 'a' * 64 } }

      Lighthouse::GraphQL::PersistedQueries.execute(schema, query: nil, extensions: extensions)

      expect(seen.first.result_or_results['errors'].first['message']).to eq('PersistedQueryNotSupported')
    end

    it 'PersistedQueries.multiplex runs a batch and dispatches the Arrays' do
      Widget.create!(name: 'w')
      seen = record
      operations = [
        { query: '{ widgets { name } }' },
        { query: nil, extensions: { 'persistedQuery' => { 'version' => 1, 'sha256Hash' => 'a' * 64 } } },
        { 'query' => '{ widgets { id } }' }
      ]

      results = Lighthouse::GraphQL::PersistedQueries.multiplex(schema, operations)

      expect(results[0].to_h).to eq('data' => { 'widgets' => [{ 'name' => 'w' }] })
      expect(results[1]['errors'].first['message']).to eq('PersistedQueryNotSupported')
      expect(results[2].to_h['data']['widgets'].size).to eq(1)

      boundaries = seen.grep(Lighthouse::Events::StartOperationOrOperations) + seen.grep(Lighthouse::Events::EndOperationOrOperations)
      expect(boundaries.map { |event| (event.try(:operation_or_operations) || event.result_or_results).size }).to eq([3, 3])
      expect(seen.count { |event| event.is_a?(Lighthouse::Events::StartExecution) }).to eq(2)
    end
  end
end
