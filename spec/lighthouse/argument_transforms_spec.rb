# frozen_string_literal: true

require 'bcrypt'

# @trim, @hash, @drop and @bind: what the resolver receives.
class ArgumentTransformsSpecCountries
  def self.call(code, _context) = { 'DE' => 'Germany' }[code]
end

RSpec.describe 'Argument transform directives' do
  include_context 'with PHP Lighthouse models'

  let(:sdl) do
    <<~GRAPHQL
      type Query {
        echo(name: String @trim, password: String @trim @hash, captcha: String @drop, input: EchoInput): String
          @field(resolver: "ArgumentTransformsSpecEcho")
        everything(a: String, input: EchoInput): String @trim @field(resolver: "ArgumentTransformsSpecEcho")
        user(id: ID! @bind(class: "LH::User")): String @field(resolver: "ArgumentTransformsSpecBound")
        byName(name: String! @bind(class: "LH::User", column: "name", with: ["tasks"])): String @field(resolver: "ArgumentTransformsSpecBound")
        users(ids: [ID!]! @bind(class: "LH::User")): String @field(resolver: "ArgumentTransformsSpecBound")
        maybe(id: ID! @bind(class: "LH::User", optional: true)): String @field(resolver: "ArgumentTransformsSpecBound")
        country(code: String! @bind(class: "ArgumentTransformsSpecCountries")): String @field(resolver: "ArgumentTransformsSpecBound")
        guarded(id: ID! @trim @bind(class: "LH::User")): String @guard @field(resolver: "ArgumentTransformsSpecBound")
      }

      input EchoInput { note: String @trim, secret: String @drop, plain: String }
    GRAPHQL
  end

  before do
    stub_const('ArgumentTransformsSpecEcho', ->(_obj, args, _ctx) { JSON.generate(Lighthouse::Support::Arguments.plain(args)) })
    stub_const('ArgumentTransformsSpecBound', lambda { |_obj, args, _ctx|
      value = args.values.first
      next 'nil' if value.nil?

      Array(value).map do |item|
        item.respond_to?(:name) ? "#{item.class.name}:#{item.name}:#{item.association(:tasks).loaded?}" : item.inspect
      end.join(',')
    })
  end

  def run(query) = schema.execute(query).to_h

  it '@trim, @hash and @drop rewrite arguments and input fields, in SDL order' do
    query = '{ echo(name: "  Ada ", password: " secret ", captcha: "x", input: { note: " hi ", secret: "s", plain: " p " }) }'
    echoed = JSON.parse(run(query).dig('data', 'echo'))

    expect(echoed.except('password')).to eq('name' => 'Ada', 'input' => { 'note' => 'hi', 'plain' => ' p ' })
    expect(BCrypt::Password.new(echoed['password'])).to eq('secret')
  end

  it '@trim on a field trims every string it takes, nested inputs included' do
    expect(JSON.parse(run('{ everything(a: " x ", input: { plain: " y " }) }').dig('data',
                                                                                   'everything'))).to eq('a' => 'x', 'input' => { 'plain' => 'y' })
  end

  describe '@bind' do
    let!(:ada) { LH::User.create!(name: 'Ada').tap { |user| LH::Task.create!(name: 't', user: user) } }

    it 'replaces an id, or another column, with the record, eager-loading `with`' do
      expect(run(%({ user(id: #{ada.id}) byName(name: "Ada") }))['data'])
        .to eq('user' => 'LH::User:Ada:false', 'byName' => 'LH::User:Ada:true')
    end

    it 'replaces a list of ids with the records, in order' do
      bob = LH::User.create!(name: 'Bob')

      expect(run(%({ users(ids: [#{bob.id}, #{ada.id}]) })).dig('data', 'users')).to eq('LH::User:Bob:false,LH::User:Ada:false')
    end

    it 'is a validation error when nothing matches, unless optional' do
      result = run('{ user(id: 0) users(ids: [0]) }')

      expect(result['errors'].map { |error| error.dig('extensions', 'validation') }).to eq([{ 'id' => ['The selected id is invalid.'] },
                                                                                            { 'ids' => ['The selected ids is invalid.'] }])
      expect(run('{ maybe(id: 0) }').dig('data', 'maybe')).to eq('nil')
    end

    it 'runs once @guard has let the call through, after the rewriting directives' do
      expect(run('{ guarded(id: "0") }')['errors'].pluck('message')).to eq(['Unauthenticated.'])
      expect(schema.execute(%({ guarded(id: " #{ada.id} ") }), context: { current_user: ada }).to_h.dig('data', 'guarded'))
        .to eq('LH::User:Ada:false')
    end

    it "takes a class's call(value, context) for what is not a model" do
      expect(run('{ country(code: "DE") }').dig('data', 'country')).to eq('"Germany"')
    end
  end
end
