require 'rails_helper'

RSpec.describe 'GraphQL caching', type: :request do
  describe '@cacheControl' do
    it 'sends the Cache-Control header the selected fields allow' do
      create(:post)

      graphql('{ posts { data { title author { name } } paginatorInfo { total } } }')

      expect(response.headers['Cache-Control']).to eq('max-age=60, public')
    end

    it 'takes the lowest maxAge across the selected fields' do
      post_record = create(:post)

      graphql("{ post(id: #{post_record.id}) { title } feed { edges { node { id } } } }")

      expect(response.headers['Cache-Control']).to eq('max-age=30, public')
    end

    it 'does not let a response be cached when a field has no hint' do
      graphql('{ publishedPostCount }')

      expect(response.headers['Cache-Control']).to eq('no-cache')
    end
  end

  describe '@cache and @clearCache' do
    let(:user) { create(:user) }

    it 'serves the cached value until a mutation clears it' do
      create(:tag, name: 'ruby')
      expect(graphql('{ tags { name } }').dig('data', 'tags')).to eq([{ 'name' => 'ruby' }])

      Tag.create!(name: 'sneaked-in') # written behind the API's back: the cache does not know
      expect(graphql('{ tags { name } }').dig('data', 'tags')).to eq([{ 'name' => 'ruby' }])

      graphql('mutation { createTag(name: "graphql") { id } }', as: user)
      expect(graphql('{ tags { name } }').dig('data', 'tags').pluck('name')).to eq(%w[ruby sneaked-in graphql])
    end
  end
end
