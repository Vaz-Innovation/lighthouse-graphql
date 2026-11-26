# frozen_string_literal: true

# What the router asks each subgraph for, sent straight to the subgraph: `_entities`
# by every kind of key, and what a subgraph answers on its own (uploads).
RSpec.describe 'The subgraphs, asked directly' do
  let(:ada) { sign_up(name: 'Ada Lovelace') }

  def entities(name, representations, selection)
    subgraph(name).execute("query($representations: [_Any!]!) { _entities(representations: $representations) { __typename #{selection} } }",
                           variables: { representations: representations })
  end

  describe 'accounts' do
    it 'finds users by either key, id or email, in one query each, null for one it does not have' do
      result = entities('accounts', [{ __typename: 'User', email: ada[:email] }, { __typename: 'User', id: ada[:id] },
                                     { __typename: 'User', id: '0' }], '... on User { id name }')

      expect(data(result)['_entities']).to eq([{ '__typename' => 'User', 'id' => ada[:id], 'name' => 'Ada Lovelace' },
                                               { '__typename' => 'User', 'id' => ada[:id], 'name' => 'Ada Lovelace' }, nil])
    end

    it 'answers an Authored (@interfaceObject) from its representation, its fields from Types::AuthoredType' do
      id = SecureRandom.uuid

      result = entities('accounts', [{ __typename: 'Authored', id: id }], '... on Authored { id likesCount likedBy { id } }')

      expect(data(result)['_entities']).to eq([{ '__typename' => 'Authored', 'id' => id, 'likesCount' => 0, 'likedBy' => [] }])
    end

    it 'refuses an unknown __typename' do
      expect(messages(entities('accounts', [{ __typename: 'Post', id: '1' }], 'id: __typename'))).to eq(['Unknown __typename `Post`.'])
    end
  end

  describe 'blog' do
    it "finds a user by id in accounts' database, with the posts the blog holds" do
      write_post(ada, title: 'Mine')

      result = entities('blog', [{ __typename: 'User', id: ada[:id], name: 'From the router' }], '... on User { postsCount signature }')

      expect(data(result)['_entities']).to eq([{ '__typename' => 'User', 'postsCount' => 1, 'signature' => 'From the router · 1 post' }])
    end

    it 'finds an Authored, the entity interface, in the model of the type it is: posts and comments alike' do
      post_id = write_post(ada, title: 'Interface')
      comment_id = router(token: ada[:token]).execute('mutation($id: ID!) { addComment(postId: $id, body: "Hi") { id } }', variables: { id: post_id })
                                             .dig('data', 'addComment', 'id')

      result = entities('blog', [{ __typename: 'Authored', id: comment_id }, { __typename: 'Authored', id: post_id }],
                        '... on Authored { id } ... on Post { title } ... on Comment { body }')

      expect(data(result)['_entities']).to eq([{ '__typename' => 'Comment', 'id' => comment_id, 'body' => 'Hi' },
                                               { '__typename' => 'Post', 'id' => post_id, 'title' => 'Interface' }])
    end

    it 'finds a tag by its key, a global id (@globalId), decoded' do
      post_id = write_post(ada, tags: [name = "global-#{SecureRandom.hex(3)}"])
      tag = data(router.execute('query($id: ID!) { post(id: $id) { tags { id } } }', variables: { id: post_id })).dig('post', 'tags', 0)

      result = entities('blog', [{ __typename: 'Tag', id: tag['id'] }], '... on Tag { name }')

      expect(data(result)['_entities']).to eq([{ '__typename' => 'Tag', 'name' => name }])
    end

    it "resolves ReadingTime entities with its type class's resolve_references, a group at once" do
      ids = Array.new(2) { |i| write_post(ada, body: 'word ' * (250 * (i + 1))) }

      result = entities('blog', ids.map { |id| { __typename: 'ReadingTime', postId: id } }, '... on ReadingTime { words caption(postTitle: "T") }')

      expect(data(result)['_entities']).to eq([{ '__typename' => 'ReadingTime', 'words' => 250, 'caption' => 'T: 2 min read' },
                                               { '__typename' => 'ReadingTime', 'words' => 500, 'caption' => 'T: 3 min read' }])
    end
  end
end
