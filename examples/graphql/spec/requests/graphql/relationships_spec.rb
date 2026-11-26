require 'rails_helper'

RSpec.describe 'GraphQL relationships', type: :request do
  let(:author) { create(:user, name: 'Grace') }
  let(:post_record) { create(:post, author: author) }

  it 'follows @belongsTo, @hasMany and @belongsToMany' do
    tag = create(:tag, name: 'rails')
    post_record.tags << tag
    create(:comment, post: post_record, body: 'First!')

    body = graphql(<<~GRAPHQL)
      {
        post(id: #{post_record.id}) {
          author { name posts { id } postsCount }
          tags { name posts { id } }
          comments(first: 5) { data { body author { id } } paginatorInfo { total } }
          commentsCount
        }
      }
    GRAPHQL

    expect(body['data']['post']).to eq(
      'author' => { 'name' => 'Grace', 'posts' => [{ 'id' => post_record.id.to_s }], 'postsCount' => 1 },
      'tags' => [{ 'name' => 'rails', 'posts' => [{ 'id' => post_record.id.to_s }] }],
      'comments' => { 'data' => [{ 'body' => 'First!', 'author' => { 'id' => Comment.last.author_id.to_s } }],
                      'paginatorInfo' => { 'total' => 1 } },
      'commentsCount' => 1
    )
  end

  it 'batches relationship loads instead of querying once per record' do
    create_list(:post, 3).each { |post| create_list(:comment, 2, post: post) }
    query = '{ posts { data { title author { name } tags { name } } } }'

    few = sql_queries { graphql(query) }.size
    create_list(:post, 5)
    many = sql_queries { graphql(query) }.size

    expect(many).to eq(few)
  end
end
