# frozen_string_literal: true

require 'time'

# A scalar's type class, as graphql-ruby's `rails g graphql:scalar` writes it.
class Types::MomentType < GraphQL::Schema::Scalar
  include Lighthouse::GraphQL::Type

  def self.coerce_input(value, _context)
    Time.iso8601(value)
  rescue ArgumentError
    raise GraphQL::CoercionError, "#{value.inspect} is not an ISO 8601 time"
  end

  def self.coerce_result(value, _context) = value.utc.iso8601
end

# Named by @scalar(class:), so neither its name nor its namespace matter.
class ScalarsSpecCents
  def self.coerce_input(value, _context) = (BigDecimal(value.to_s) * 100).to_i

  def self.coerce_result(value, _context) = format('%.2f', value / 100.0)
end

# Does not include the concern: graphql-ruby's, not Lighthouse's.
class Types::OpaqueType < GraphQL::Schema::Scalar
  def self.coerce_result(_value, _context) = 'never'
end

class Types::OtherScalarBase < GraphQL::Schema::Scalar; end

RSpec.describe 'Scalars' do
  let(:sdl) do
    <<~GRAPHQL
      scalar Moment
      scalar Price @scalar(class: "ScalarsSpecCents")
      scalar Opaque

      type Query {
        later(at: Moment!): Moment @field(resolver: "ScalarsSpecLater")
        inputClass(at: Moment!): String @field(resolver: "ScalarsSpecClass")
        double(price: Price!): Price @field(resolver: "ScalarsSpecDouble")
        opaque(value: Opaque): Opaque @field(resolver: "ScalarsSpecEcho")
      }
    GRAPHQL
  end

  before do
    stub_const('ScalarsSpecLater', ->(_obj, args, _ctx) { args[:at] + 3600 })
    stub_const('ScalarsSpecClass', ->(_obj, args, _ctx) { args[:at].class.name })
    stub_const('ScalarsSpecDouble', ->(_obj, args, _ctx) { args[:price] * 2 })
    stub_const('ScalarsSpecEcho', ->(_obj, args, _ctx) { args[:value] })
  end

  def run(query, variables = {}) = build_schema(sdl).execute(query, variables: variables).to_h

  it "reads and writes a scalar's values through its type class" do
    expect(run('{ later(at: "2026-01-01T10:00:00Z") inputClass(at: "2026-01-01T10:00:00Z") }'))
      .to eq('data' => { 'later' => '2026-01-01T11:00:00Z', 'inputClass' => 'Time' })
  end

  it 'coerces variables too' do
    expect(run('query($at: Moment!) { later(at: $at) }', { 'at' => '2026-01-01T10:00:00Z' }))
      .to eq('data' => { 'later' => '2026-01-01T11:00:00Z' })
  end

  it 'turns a GraphQL::CoercionError into an invalid argument' do
    result = run('{ later(at: "yesterday") }')

    expect(result['errors'].pluck('message').join).to include('"yesterday" is not an ISO 8601 time')
    expect(result['data']).to be_nil
  end

  it 'uses the class @scalar(class:) names' do
    expect(run('{ double(price: "1.25") }')).to eq('data' => { 'double' => '2.50' })
  end

  it 'passes the values of a scalar with no Lighthouse class through unchanged' do
    expect(run('{ opaque(value: "as is") }')).to eq('data' => { 'opaque' => 'as is' })
  end

  it 'refuses a @scalar(class:) naming no coercing class when the schema is built' do
    expect { build_schema('scalar Odd @scalar(class: "Nope") type Query { x: Odd }') }
      .to raise_error(Lighthouse::DefinitionError, /@scalar\(class: "Nope"\) on Odd names no class/)
  end

  it "requires a type class to inherit from the schema's base_types[:scalar]" do
    expect { build_schema(sdl, base_types: { scalar: Types::OtherScalarBase }) }
      .to raise_error(Lighthouse::DefinitionError, /Types::MomentType resolves the Moment scalar, so it must inherit from Types::OtherScalarBase/)
  end
end
