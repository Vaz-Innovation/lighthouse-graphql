# frozen_string_literal: true

module Events; end

class Events::PostPublished
  attr_reader :post

  def initialize(post)
    @post = post
  end
end

class Events::Audited
  attr_reader :value

  def initialize(value)
    @value = value
  end
end

RSpec.describe '@event' do
  let(:sdl) do
    <<~GRAPHQL
      type Query {
        post(id: ID! @eq): Post @find @event(dispatch: "PostPublished")
        posts: [Post!]! @all @event(dispatch: "PostPublished") @event(dispatch: "Events::Audited")
        explode: Post @field(resolver: "EventDirectiveSpecExplode") @event(dispatch: "PostPublished")
        guarded(id: ID! @eq): Post @find @guard @event(dispatch: "PostPublished")
        count: Int @field(resolver: "EventDirectiveSpecCount") @cache @event(dispatch: "Audited")
      }

      type Post {
        id: ID!
        title: String
      }
    GRAPHQL
  end
  let(:schema) { build_schema(sdl) }
  let!(:post) { Post.create!(title: 'Hello') }
  let(:heard) { [] }

  before do
    stub_const('EventDirectiveSpecExplode', Class.new { def self.call(*) = raise(GraphQL::ExecutionError, 'boom') })
    stub_const('EventDirectiveSpecCount', Class.new { def self.call(*) = 3 })
    Lighthouse::Events.listen(Events::PostPublished) { |event| heard << event }
    Lighthouse::Events.listen(Events::Audited) { |event| heard << event }
  end

  it 'dispatches the event, built with the resolved value, and returns the value unchanged' do
    result = schema.execute("{ post(id: #{post.id}) { title } }").to_h

    expect(result).to eq('data' => { 'post' => { 'title' => 'Hello' } })
    expect(heard.size).to eq(1)
    expect(heard.first).to be_a(Events::PostPublished)
    expect(heard.first.post).to eq(post)
  end

  it 'dispatches each of a repeated @event exactly once' do
    Post.create!(title: 'Second')

    schema.execute('{ posts { id } }')

    expect(heard.map(&:class)).to contain_exactly(Events::PostPublished, Events::Audited)
    expect(heard.map { |event| event.try(:post) || event.value }.map(&:size)).to eq([2, 2])
  end

  it 'dispatches nothing when the field raises' do
    result = schema.execute('{ explode { id } }').to_h

    expect(result['errors'].first['message']).to eq('boom')
    expect(heard).to be_empty
  end

  it 'dispatches nothing when @guard rejects the request' do
    result = schema.execute("{ guarded(id: #{post.id}) { id } }").to_h

    expect(result['errors']).not_to be_empty
    expect(heard).to be_empty
  end

  it 'looks the class up in Config.namespaces[:events], and falls back to the bare name' do
    schema.execute('{ count }')

    expect(heard.map(&:class)).to eq([Events::Audited])
    expect(heard.first.value).to eq(3)
  end

  it 'honors the configured events namespaces' do
    stub_const('Domain', Module.new)
    stub_const('Domain::Shipped', Class.new { def initialize(_value); end })
    shipped = []
    Lighthouse.configure { |config| config.namespaces = { events: ['Domain'] } }
    Lighthouse::Events.listen(Domain::Shipped) { |event| shipped << event }

    build_schema('type Query { n: Int @field(resolver: "EventDirectiveSpecCount") @event(dispatch: "Shipped") }').execute('{ n }')

    expect(shipped.size).to eq(1)
  end

  it 'fails the schema build when the class cannot be found' do
    expect { build_schema('type Query { n: Int @field(resolver: "EventDirectiveSpecCount") @event(dispatch: "Nope") }') }
      .to raise_error(Lighthouse::DefinitionError, /@event on Query\.n: no event class Nope/)
  end

  it 'is injected, repeatable, with its definition' do
    definition = Lighthouse::DirectiveRegistry.default.directive_definitions['event']

    expect(definition).to eq('directive @event(dispatch: String!) repeatable on FIELD_DEFINITION')
    expect(Lighthouse::DirectiveRegistry.default.resolution_order('event')).to eq(1)
  end
end
