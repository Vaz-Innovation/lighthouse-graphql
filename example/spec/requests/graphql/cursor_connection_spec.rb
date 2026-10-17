require 'rails_helper'

# Relay-style cursor pagination, the way a client walks it: ask for a page,
# then pass its pageInfo.endCursor as `after` until hasNextPage is false.
RSpec.describe 'GraphQL cursor connections', type: :request do
  let(:author) { create(:user) }

  let(:query) do
    <<~GRAPHQL
      query UserComments($id: ID!, $first: Int!, $after: String) {
        user(id: $id) {
          comments(first: $first, after: $after) {
            edges { cursor node { body } }
            pageInfo { hasNextPage hasPreviousPage startCursor endCursor total count currentPage lastPage }
          }
        }
      }
    GRAPHQL
  end

  def page(first:, after: nil)
    graphql(query, variables: { id: author.id, first: first, after: after }).dig('data', 'user', 'comments')
  end

  before do
    5.times { |i| create(:comment, author: author, body: "Comment #{i + 1}", created_at: (5 - i).hours.ago) }
    create(:comment, body: "Someone else's")
  end

  it 'describes the first page' do
    first = page(first: 2)

    expect(first['edges'].map { |edge| edge.dig('node', 'body') }).to eq(['Comment 1', 'Comment 2'])
    expect(first['pageInfo']).to include(
      'hasNextPage' => true, 'hasPreviousPage' => false, 'total' => 5, 'count' => 2, 'currentPage' => 1, 'lastPage' => 3,
      'startCursor' => first['edges'].first['cursor'], 'endCursor' => first['edges'].last['cursor']
    )
  end

  it 'continues after the cursor it is given' do
    first = page(first: 2)
    second = page(first: 2, after: first.dig('pageInfo', 'endCursor'))

    expect(second['edges'].map { |edge| edge.dig('node', 'body') }).to eq(['Comment 3', 'Comment 4'])
    expect(second['pageInfo']).to include('hasPreviousPage' => true, 'currentPage' => 2)
  end

  it 'walks every page, in order, without repeating or skipping a comment' do
    bodies = []
    after = nil
    loop do
      current = page(first: 2, after: after)
      bodies.concat(current['edges'].map { |edge| edge.dig('node', 'body') })
      break unless current.dig('pageInfo', 'hasNextPage')

      after = current.dig('pageInfo', 'endCursor')
    end

    expect(bodies).to eq((1..5).map { |n| "Comment #{n}" })
  end

  it "loads every user's page in one query, and every total in another" do
    query = '{ users(first: 50) { data { comments(first: 2) { edges { node { body } } pageInfo { total } } } } }'
    few = sql_queries { graphql(query) }.size
    create_list(:user, 5).each { |user| create_list(:comment, 3, author: user) }

    expect(sql_queries { graphql(query) }.size).to eq(few)
  end

  it 'uses defaultCount when the client omits first' do
    expect(graphql("{ user(id: #{author.id}) { comments { pageInfo { count } } } }").dig('data', 'user', 'comments', 'pageInfo', 'count')).to eq(5)
  end
end
