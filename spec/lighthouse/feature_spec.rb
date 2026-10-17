# frozen_string_literal: true

require 'flipper'

RSpec.describe '@feature' do
  let(:sdl) do
    <<~GRAPHQL
      type Query {
        name: String @field(resolver: "FeatureSpecText")
        beta: String @field(resolver: "FeatureSpecText") @feature(name: "beta")
        legacy: String @field(resolver: "FeatureSpecText") @feature(name: "beta", when: INACTIVE)
        hidden: Hidden @field(resolver: "FeatureSpecGadget") @feature(name: "never")
        gadget: Gadget @field(resolver: "FeatureSpecGadget")
        gadgets: [Gadget!]! @field(resolver: "FeatureSpecGadgets")
      }

      type Gadget @feature(name: "gadgets") {
        id: ID
      }

      type Hidden {
        id: ID
      }
    GRAPHQL
  end
  let(:schema) { build_schema(sdl) }
  let(:actor_class) { Struct.new(:id) { def flipper_id = "User;#{id}" } }

  before do
    stub_const('FeatureSpecText', Class.new { def self.call(*) = 'ok' })
    stub_const('FeatureSpecGadget', Class.new { def self.call(*) = { 'id' => '1' } })
    stub_const('FeatureSpecGadgets', Class.new { def self.call(*) = [{ 'id' => '1' }] })
    Flipper.instance = Flipper.new(Flipper::Adapters::Memory.new)
  end

  def run(query, context = {})
    schema.execute(query, context: context)
  end

  def field_names(type_name, context = {})
    result = run("{ __type(name: \"#{type_name}\") { fields { name } } }", context)
    result['data']['__type']&.fetch('fields')&.pluck('name')
  end

  describe 'on a field' do
    it 'hides it while the feature is inactive' do
      result = run('{ beta }')

      expect(result['data']).to be_nil
      expect(result['errors'].pick('message')).to include("Field 'beta' doesn't exist on type 'Query'")
    end

    it 'includes it while the feature is active' do
      Flipper.enable(:beta)

      expect(run('{ beta }')['data']).to eq('beta' => 'ok')
    end

    it 'includes a field that is not annotated whatever the feature' do
      expect(run('{ name }')['data']).to eq('name' => 'ok')
    end

    it 'inverts with when: INACTIVE' do
      expect(run('{ legacy }')['data']).to eq('legacy' => 'ok')

      Flipper.enable(:beta)
      result = run('{ legacy }')

      expect(result['data']).to be_nil
      expect(result['errors'].pick('message')).to include("Field 'legacy' doesn't exist on type 'Query'")
    end

    it 'follows the feature from one query to the next' do
      expect(run('{ beta }')['errors']).to be_present

      Flipper.enable(:beta)
      expect(run('{ beta }')['errors']).to be_nil

      Flipper.disable(:beta)
      expect(run('{ beta }')['errors']).to be_present
    end
  end

  describe 'on an object type' do
    it 'hides the type and the fields returning it' do
      result = run('{ gadget { id } }')

      expect(result['errors'].pick('message')).to include("Field 'gadget' doesn't exist on type 'Query'")
      expect(run('{ gadgets { id } }')['errors']).to be_present
    end

    it 'includes them while the feature is active' do
      Flipper.enable(:gadgets)

      expect(run('{ gadget { id } gadgets { id } }')['data']).to eq('gadget' => { 'id' => '1' }, 'gadgets' => [{ 'id' => '1' }])
    end

    it 'does not break the schema' do
      expect(run('{ name }')['errors']).to be_nil
    end
  end

  describe 'introspection' do
    it 'lists the fields and types whose feature is on' do
      expect(field_names('Query')).to contain_exactly('name', 'legacy')
      expect(run('{ __type(name: "Gadget") { name } }')['data']).to eq('__type' => nil)

      Flipper.enable(:beta)
      Flipper.enable(:gadgets)

      expect(field_names('Query')).to contain_exactly('name', 'beta', 'gadget', 'gadgets')
      expect(run('{ __type(name: "Gadget") { name } }')['data']).to eq('__type' => { 'name' => 'Gadget' })
    end

    it 'prints the schema as the features stand for no actor' do
      expect(schema.to_definition).not_to include('beta: String', 'type Gadget')

      Flipper.enable(:beta)
      Flipper.enable(:gadgets)

      expect(schema.to_definition).to include('beta: String', 'type Gadget')
    end
  end

  describe 'per actor' do
    let(:alice) { actor_class.new(1) }
    let(:bob) { actor_class.new(2) }

    before { Flipper.enable_actor(:beta, alice) }

    it 'includes the field for the enabled actor only' do
      expect(run('{ beta }', current_user: alice)['data']).to eq('beta' => 'ok')
      expect(run('{ beta }', current_user: bob)['errors']).to be_present
      expect(run('{ beta }')['errors']).to be_present
    end

    it 'reads the actor from Config.feature_actor' do
      Lighthouse::Config.feature_actor = ->(ctx) { ctx[:account] }

      expect(run('{ beta }', current_user: alice)['errors']).to be_present
      expect(run('{ beta }', account: alice)['data']).to eq('beta' => 'ok')
    end
  end

  describe 'with a custom Config.feature_checker' do
    it 'asks it for the feature name, the actor and the context' do
      calls = []
      Lighthouse::Config.feature_checker = lambda { |name, actor, ctx|
        calls << [name, actor, ctx[:tag]]
        name == 'beta'
      }

      expect(run('{ beta }', current_user: :me, tag: 1)['data']).to eq('beta' => 'ok')
      expect(calls).to include(['beta', :me, 1])
    end

    it 'does not need Flipper' do
      hide_const('Flipper')
      Lighthouse::Config.feature_checker = ->(_name, _actor, _ctx) { true }

      expect(run('{ beta }')['data']).to eq('beta' => 'ok')
    end

    it 'checks each feature once per query' do
      calls = Hash.new(0)
      Lighthouse::Config.feature_checker = lambda { |name, _actor, _ctx|
        calls[name] += 1
        true
      }

      run('{ beta legacy gadget { id } gadgets { id } __schema { types { name fields { name } } } }')

      expect(calls).to eq('beta' => 1, 'never' => 1, 'gadgets' => 1)
    end

    it 'checks again in the next query' do
      calls = 0
      Lighthouse::Config.feature_checker = lambda { |_name, _actor, _ctx|
        calls += 1
        true
      }

      2.times { run('{ beta }') }

      expect(calls).to eq(2)
    end
  end

  describe 'without Flipper' do
    it 'tells how to configure the check' do
      hide_const('Flipper')

      expect { run('{ beta }') }.to raise_error(/Config.feature_checker/)
    end
  end

  describe 'at build time' do
    it 'requires a name' do
      expect { build_schema('type Query { a: String @feature(name: "") }') }
        .to raise_error(Lighthouse::DefinitionError, /@feature on Query.a needs a feature `name`/)
    end

    it 'injects the directive and its FeatureState enum' do
      expect(schema.to_definition).to include('enum FeatureState')
      expect(schema.directives).to have_key('feature')
    end
  end

  describe 'with GraphQL::Schema::Visibility' do
    let(:schema) do
      Lighthouse::GraphQL::SchemaFactory.build_base_schema(sdl: sdl, base_types: {}, federation: false,
                                                           schema_options: { using: { GraphQL::Schema::Visibility => {} } })
    end

    it 'hides per query too' do
      expect(run('{ beta }')['errors']).to be_present

      Flipper.enable(:beta)

      expect(run('{ beta }')['data']).to eq('beta' => 'ok')
    end
  end
end
