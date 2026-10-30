# frozen_string_literal: true

require 'global_id'

# A schema on Rails' GlobalID, as graphql-ruby's install writes it: @globalId
# decodes an id without loading its record, as PHP Lighthouse's GlobalId does.
RSpec.describe '@globalId(decode:) on Rails GlobalIDs' do
  let(:base) do
    build_schema(<<~GRAPHQL)
      type ParanoidItem { id: ID! @globalId name: String }

      type Query {
        item(id: ID! @globalId(decode: ID) @eq): ParanoidItem @find
        itemType(id: ID! @globalId(decode: TYPE)): String @field(resolver: "GlobalIdDecodeSpecEcho")
      }

      type Mutation {
        restoreItem(id: ID! @globalId(decode: ID) @whereKey): ParanoidItem @restore
      }
    GRAPHQL
  end
  let(:schema) do
    Class.new(base) do
      def self.id_from_object(object, _type, _context) = object.to_gid_param
      def self.object_from_id(global_id, _context) = GlobalID.find(global_id)
    end
  end
  let(:item) { ParanoidItem.create!(name: 'p') }

  before do
    GlobalID.app ||= 'lighthouse-spec'
    ParanoidItem.include(GlobalID::Identification) unless ParanoidItem.include?(GlobalID::Identification)
    stub_const('GlobalIdDecodeSpecEcho', ->(_obj, args, _ctx) { args[:id] })
  end

  def selects(&block)
    queries = []
    callback = ->(*, payload) { queries << payload[:sql] if payload[:sql].match?(/\ASELECT .*paranoid_items/i) }
    ActiveSupport::Notifications.subscribed(callback, 'sql.active_record', &block)
    queries
  end

  it 'finds the record with the one SELECT of @find' do
    id = item.to_gid_param
    result = nil
    queries = selects { result = schema.execute(%({ item(id: "#{id}") { id name } })).to_h }

    expect(result).to eq('data' => { 'item' => { 'id' => id, 'name' => 'p' } })
    expect(queries.size).to eq(1)
  end

  it 'decodes the type without reading the database' do
    queries = selects { expect(schema.execute(%({ itemType(id: "#{item.to_gid_param}") })).to_h).to eq('data' => { 'itemType' => 'ParanoidItem' }) }

    expect(queries).to be_empty
  end

  it 'decodes the id of a record a default scope hides, so @restore finds it in the trash' do
    id = item.to_gid_param
    item.destroy

    expect(schema.execute(%(mutation { restoreItem(id: "#{id}") { name } })).to_h).to eq('data' => { 'restoreItem' => { 'name' => 'p' } })
    expect(ParanoidItem.find(item.id)).to be_present
  end
end
