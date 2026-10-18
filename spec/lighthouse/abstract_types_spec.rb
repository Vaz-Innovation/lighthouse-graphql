# frozen_string_literal: true

# What a union's or interface's values resolve to.
module AbstractSpec
  Book = Struct.new(:title, :pages)
  Movie = Struct.new(:title, :minutes)
  # A subclass with no type of its own resolves to its superclass's (STI).
  class Novel < Book; end
  Unknown = Struct.new(:title)

  BOOK = Book.new('Dune', 412)
  NOVEL = Novel.new('Emma', 474)
  MOVIE = Movie.new('Alien', 117)
  HASH = { __typename: 'Movie', title: 'Heat', minutes: 170 }.freeze
end

# A union's own resolution, as graphql-ruby writes it: a type class (or name) per value.
class Types::ShelfItemType < GraphQL::Schema::Union
  include Lighthouse::GraphQL::Type

  def self.resolve_type(object, _context) = object == AbstractSpec::BOOK ? Types::LongReadType : nil
end

class Types::LongReadType < GraphQL::Schema::Object; end

# An interface's own resolution, in graphql-ruby's definition_methods.
module Types::TitledType
  include GraphQL::Schema::Interface
  include Lighthouse::GraphQL::Type

  definition_methods do
    def resolve_type(object, _context) = object.is_a?(AbstractSpec::Movie) ? 'Film' : nil
  end
end

class AbstractSpecPicker
  def self.call(object, _context) = object.is_a?(AbstractSpec::Book) ? 'Movie' : 'Book'
end

RSpec.describe 'Union and interface types' do
  let(:sdl) do
    <<~GRAPHQL
      type Query {
        media: [Media!]! @field(resolver: "AbstractSpecMedia")
        titled: [Titled!]! @field(resolver: "AbstractSpecMedia")
        shelf: [ShelfItem!]! @field(resolver: "AbstractSpecMedia")
        features: [Feature!]! @all(model: "Post")
        swapped: [Swapped!]! @field(resolver: "AbstractSpecMedia")
        unknown: [Media!]! @field(resolver: "AbstractSpecUnknown")
      }

      union Media = Book | Movie
      union ShelfItem = LongRead | Book | Movie
      union Feature = Story | Movie
      union Swapped @union(resolveType: "AbstractSpecPicker") = Book | Movie

      interface Titled { title: String }

      type Book implements Titled { title: String pages: Int }
      type Movie implements Titled { title: String minutes: Int }
      type Film implements Titled { title: String }
      type LongRead { title: String }
      type Story @model(class: "Post") { title: String }
    GRAPHQL
  end

  before do
    stub_const('AbstractSpecMedia', ->(*) { [AbstractSpec::BOOK, AbstractSpec::NOVEL, AbstractSpec::MOVIE, AbstractSpec::HASH] })
    stub_const('AbstractSpecUnknown', ->(*) { [AbstractSpec::Unknown.new('?')] })
  end

  def run(query) = build_schema(sdl).execute(query).to_h

  def typenames(query, field) = run(query).dig('data', field).pluck('__typename')

  it "resolves a union's values to the types named after their classes, a superclass's, or a Hash's __typename" do
    result = run('{ media { __typename ... on Book { pages } ... on Movie { minutes } } }')

    expect(result.dig('data', 'media')).to eq([{ '__typename' => 'Book', 'pages' => 412 }, { '__typename' => 'Book', 'pages' => 474 },
                                               { '__typename' => 'Movie', 'minutes' => 117 }, { '__typename' => 'Movie', 'minutes' => 170 }])
  end

  it 'resolves a record to the type whose @model names its model' do
    Post.create!(title: 'Hello')

    expect(run('{ features { __typename ... on Story { title } } }').dig('data', 'features'))
      .to eq([{ '__typename' => 'Story', 'title' => 'Hello' }])
  end

  it "asks the union's type class first, which may answer with a type class, and falls back to the default on nil" do
    expect(typenames('{ shelf { __typename } }', 'shelf')).to eq(%w[LongRead Book Movie Movie])
  end

  it "asks the interface's type class first, with the default for what it leaves" do
    expect(typenames('{ titled { __typename title } }', 'titled')).to eq(%w[Book Book Film Movie])
  end

  it 'asks the class @union(resolveType:) names' do
    expect(typenames('{ swapped { __typename } }', 'swapped')).to eq(%w[Movie Movie Book Book])
  end

  it 'raises a DefinitionError naming the ways out when no step resolves a value' do
    expect { run('{ unknown { __typename } }') }
      .to raise_error(Lighthouse::DefinitionError, /could not tell the type of a AbstractSpec::Unknown in the union Media \(Book \| Movie\)/)
  end

  it 'raises when a class answers with a type the union does not include' do
    stub_const('AbstractSpecPicker', Class.new { def self.call(*) = 'Film' })

    expect { run('{ swapped { __typename } }') }
      .to raise_error(Lighthouse::DefinitionError, /Swapped resolved a .* to Film, which is not one of its types/)
  end

  describe 'at build time' do
    it 'refuses a @union(resolveType:) naming no class' do
      expect { build_schema('type Query { x: U } union U @union(resolveType: "Nope") = A type A { id: ID }') }
        .to raise_error(Lighthouse::DefinitionError, /@union\(resolveType: "Nope"\) on U names no class/)
    end

    it "requires a union's type class to inherit from the schema's base_types[:union]" do
      expect { build_schema(sdl, base_types: { union: Class.new(GraphQL::Schema::Union) }) }
        .to raise_error(Lighthouse::DefinitionError, /Types::ShelfItemType resolves the ShelfItem union, so it must inherit from/)
    end

    it 'refuses a type class of another kind than the SDL type' do
      expect { build_schema('type Query { x: Titled } union Titled = A type A { id: ID }') }
        .to raise_error(Lighthouse::DefinitionError, /Types::TitledType is a type class of kind interface, but Titled is of kind union in the schema/)
    end
  end
end
