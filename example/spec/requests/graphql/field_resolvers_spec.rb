require 'rails_helper'

RSpec.describe 'GraphQL @field resolvers', type: :request do
  let(:rails) { create(:tag, name: 'rails') }
  let(:graphql_tag) { create(:tag, name: 'graphql') }

  describe 'on a field of Post: the post is the resolver\'s object' do
    it 'resolves tagsCount for each post in a list' do
      create(:post, title: 'Two tags', tags: [rails, graphql_tag], created_at: 1.day.ago)
      create(:post, title: 'No tags', created_at: 2.days.ago)

      body = graphql('{ posts { data { title tagsCount } } }')

      expect(body.dig('data', 'posts', 'data')).to eq([{ 'title' => 'Two tags', 'tagsCount' => 2 },
                                                       { 'title' => 'No tags', 'tagsCount' => 0 }])
    end

    it 'resolves it on a single post too, beside the fields directives resolve' do
      post_record = create(:post, tags: [rails], body: 'Directives say what a field does, classes say how.')

      body = graphql("{ post(id: #{post_record.id}) { tags { name } tagsCount excerpt(length: 20) } }")

      expect(body.dig('data', 'post')).to eq('tags' => [{ 'name' => 'rails' }], 'tagsCount' => 1, 'excerpt' => 'Directives say...')
    end

    it 'passes the field\'s arguments, with the SDL default when one is left out' do
      post_record = create(:post, body: "#{'word ' * 30}end")

      body = graphql("{ post(id: #{post_record.id}) { short: excerpt(length: 12) long: excerpt } }")

      expect(body.dig('data', 'post', 'short')).to eq('word word...')
      expect(body.dig('data', 'post', 'long').length).to be <= 80
    end

    it 'resolves wherever a Post appears, here under the user Resolvers::Me returns' do
      user = create(:user)
      create(:post, author: user, tags: [rails, graphql_tag])

      body = graphql('{ me { posts { tagsCount } } }', as: user)

      expect(body.dig('data', 'me', 'posts')).to eq([{ 'tagsCount' => 2 }])
    end

    it 'batches the tags of every post into one query instead of one per post' do
      create_list(:post, 2, tags: [rails])
      query = '{ posts { data { tagsCount } } }'

      few = sql_queries { graphql(query) }.size
      create_list(:post, 5, tags: [rails, graphql_tag])
      many = sql_queries { graphql(query) }.size

      expect(many).to eq(few)
    end
  end

  describe 'on a Query field' do
    it 'resolves popularTags with the class @field names, counting published posts only' do
      create_list(:post, 2, tags: [graphql_tag])
      create(:post, tags: [rails, graphql_tag])
      create_list(:post, 3, :draft, tags: [rails])
      create(:tag, name: 'unused')

      expect(graphql('{ popularTags { name } }').dig('data', 'popularTags')).to eq([{ 'name' => 'graphql' }, { 'name' => 'rails' }])
      expect(graphql('{ popularTags(limit: 1) { name } }').dig('data', 'popularTags')).to eq([{ 'name' => 'graphql' }])
    end
  end
end
