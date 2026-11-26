require 'rails_helper'

RSpec.describe 'GraphQL unions, interfaces, scalars and @method', type: :request do
  let(:grace) { create(:user, name: 'Grace Hopper') }

  it 'resolves each value of a union to the type of its model' do
    create(:post, title: 'Grace notes', author: create(:user, name: 'Ada'))
    grace
    create(:post, :draft, title: 'Grace draft')

    body = graphql(<<~GRAPHQL)
      { search(term: "Grace") { __typename ... on Post { title } ... on User { name } } }
    GRAPHQL

    expect(body.dig('data', 'search')).to eq([{ '__typename' => 'Post', 'title' => 'Grace notes' },
                                              { '__typename' => 'User', 'name' => 'Grace Hopper' }])
  end

  it "resolves each value of an interface to its model's type, with the interface's fields and each type's own" do
    post_record = create(:post, title: 'Hello', author: grace, created_at: 2.hours.ago)
    comment = create(:comment, post: post_record, body: 'First!', created_at: 1.hour.ago)

    body = graphql(<<~GRAPHQL)
      { latestActivity { __typename id author { name } ... on Post { title } ... on Comment { body } } }
    GRAPHQL

    expect(body.dig('data', 'latestActivity')).to eq(
      [{ '__typename' => 'Comment', 'id' => comment.id.to_s, 'author' => { 'name' => comment.author.name }, 'body' => 'First!' },
       { '__typename' => 'Post', 'id' => post_record.id.to_s, 'author' => { 'name' => 'Grace Hopper' }, 'title' => 'Hello' }]
    )
  end

  describe 'a scalar with a type class' do
    it 'writes a Time as ISO 8601 and reads an argument as a Time' do
      old = create(:post, title: 'Old', created_at: Time.utc(2026, 1, 1, 9))
      create(:post, title: 'New', created_at: Time.utc(2026, 3, 1, 9))

      body = graphql('query($since: DateTime) { latestActivity(since: $since) { ... on Post { title createdAt } } }',
                     variables: { since: '2026-02-01T00:00:00Z' })

      expect(body.dig('data', 'latestActivity')).to eq([{ 'title' => 'New', 'createdAt' => '2026-03-01T09:00:00Z' }])
      expect(graphql("{ post(id: #{old.id}) { createdAt } }").dig('data', 'post', 'createdAt')).to eq('2026-01-01T09:00:00Z')
    end

    it 'refuses a value it cannot read, with its message' do
      body = graphql('{ latestActivity(since: "last week") { id } }')

      expect(error_messages(body).join).to include('"last week" is not an ISO 8601 date and time')
    end
  end

  it "passes a field's argument to the model method @method calls" do
    post_record = create(:post, body: 'one two three four five')

    body = graphql("{ post(id: #{post_record.id}) { summary short: summary(words: 2) } }")

    expect(body.dig('data', 'post')).to eq('summary' => 'one two three four five', 'short' => 'one two')
  end
end
