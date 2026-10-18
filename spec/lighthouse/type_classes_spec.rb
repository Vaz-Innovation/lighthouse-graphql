# frozen_string_literal: true

# Types::<Name>Type, graphql-ruby's type classes: when one includes
# Lighthouse::GraphQL::Type, its methods resolve the fields of the SDL type of
# the same name.
class Types::BaseObject < GraphQL::Schema::Object
  def shout(text) = "#{text.upcase}!"
end

class Types::GadgetType < Types::BaseObject
  include Lighthouse::GraphQL::Type

  def label = shout(object.name)

  def price_in(currency:, rate: 1.0) = "#{(object.cents * rate / 100.0).round(2)} #{currency}"

  def viewer = context[:viewer]

  def stats = { weight: object.grams }

  def name = 'never: @rename wins'
end

# Not a model: a Hash the parent's method returns, and fields computed from it.
class Types::GadgetStatsType < Types::BaseObject
  include Lighthouse::GraphQL::Type

  def kilos = object[:weight] / 1000.0
end

# The type of Post records (@model in the SDL): its methods only ever see a Post.
class Types::ArticleType < Types::BaseObject
  include Lighthouse::GraphQL::Type

  def headline = object.title.upcase
end

# Does not opt in, so it is not Lighthouse's: its methods never resolve a field.
class Types::WidgetType < Types::BaseObject
  def name = 'never: not a Lighthouse type'
end

# Not a GraphQL::Schema::Object at all, and not Lighthouse's either.
class Types::LegacyType
  def name = 'never'
end

class Types::OtherBase < GraphQL::Schema::Object; end

TypeClassesSpecGadget = Struct.new(:name, :cents, :grams, :title)

RSpec.describe 'Type classes (Types::<Name>Type including Lighthouse::GraphQL::Type)' do
  let(:sdl) do
    <<~GRAPHQL
      type Query {
        gadget: Gadget @field(resolver: "TypeClassesSpecGadgetResolver")
        article: Article @first(model: "Post")
        notAnArticle: Article @field(resolver: "TypeClassesSpecGadgetResolver")
        widget: Widget @field(resolver: "TypeClassesSpecGadgetResolver")
        legacy: Legacy @field(resolver: "TypeClassesSpecGadgetResolver")
      }

      type Gadget {
        name: String @rename(attribute: "title")
        cents: Int
        label: String
        priceIn(currency: String!, rate: Float = 2.0): String
        viewer: String
        guarded: String @guard
        stats: GadgetStats
      }

      type GadgetStats {
        weight: Int
        kilos: Float
      }

      type Article @model(class: "Post") {
        title: String
        headline: String
      }

      type Widget { name: String }
      type Legacy { name: String }
    GRAPHQL
  end

  before do
    stub_const('TypeClassesSpecGadgetResolver', ->(_obj, _args, _ctx) { TypeClassesSpecGadget.new('lamp', 1250, 2500, 'Lamp') })
  end

  def run(query, context = {})
    build_schema(sdl).execute(query, context: context).to_h
  end

  it 'resolves a field with the method of the type class, which receives the parent as object' do
    expect(run('{ gadget { label cents } }')).to eq('data' => { 'gadget' => { 'label' => 'LAMP!', 'cents' => 1250 } })
  end

  it 'passes the arguments as snake_case keywords, with the SDL default, and the context' do
    result = run('{ gadget { priceIn(currency: "EUR") plain: priceIn(currency: "USD", rate: 1.0) viewer } }', { viewer: 'ada' })

    expect(result).to eq('data' => { 'gadget' => { 'priceIn' => '25.0 EUR', 'plain' => '12.5 USD', 'viewer' => 'ada' } })
  end

  it 'resolves the fields of a type that is not a model, read and computed from what the parent returns' do
    expect(run('{ gadget { stats { weight kilos } } }')).to eq('data' => { 'gadget' => { 'stats' => { 'weight' => 2500, 'kilos' => 2.5 } } })
  end

  it 'leaves a field with a resolving directive to the directive' do
    expect(run('{ gadget { name } }')).to eq('data' => { 'gadget' => { 'name' => 'Lamp' } })
  end

  it 'runs wrapping directives around the method' do
    expect(run('{ gadget { guarded } }')['errors'].pluck('message')).to eq(['Unauthenticated.'])
  end

  it 'leaves alone a type class that does not include the concern, whatever it is' do
    expect(run('{ widget { name } legacy { name } }')).to eq('data' => { 'widget' => { 'name' => 'lamp' }, 'legacy' => { 'name' => 'lamp' } })
  end

  it 'looks the classes up in Config.namespaces[:types]' do
    Lighthouse.configure { |c| c.namespaces = { types: ['Custom'] } }

    expect(run('{ gadget { label } }')).to eq('data' => { 'gadget' => { 'label' => nil } })
  end

  describe '@model' do
    it "resolves with the type's methods a record of the model @model names" do
      Post.create!(title: 'Hello')

      expect(run('{ article { title headline } }')).to eq('data' => { 'article' => { 'title' => 'Hello', 'headline' => 'HELLO' } })
    end

    it 'reports a parent of another class through on_error, and does not run the method' do
      errors = []
      Lighthouse.configure { |c| c.on_error = ->(error, _ctx) { errors << error } }

      expect(run('{ notAnArticle { headline } }')).to eq('data' => { 'notAnArticle' => { 'headline' => nil } })
      expect(errors.map(&:message)).to eq(
        ['Article.headline resolves with Types::ArticleType, but its parent is a TypeClassesSpecGadget, not a Post (@model).']
      )
    end
  end

  it 'can only be included in a graphql-ruby type' do
    expect { Class.new { include Lighthouse::GraphQL::Type } }
      .to raise_error(Lighthouse::DefinitionError, /which is for graphql-ruby types/)
  end

  it "requires the class to inherit from the schema's base_types[:object]" do
    expect { build_schema(sdl, base_types: { object: Types::OtherBase }) }
      .to raise_error(Lighthouse::DefinitionError, /Types::GadgetType resolves the Gadget type, so it must inherit from Types::OtherBase/)
  end
end
