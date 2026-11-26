# frozen_string_literal: true

# What Federation does with the two subgraphs, asked through the router: entities
# resolved across them, and each federation directive doing its part.
RSpec.describe 'Federation through Apollo Router' do
  let(:ada) { sign_up(name: 'Ada Lovelace') }

  # The subgraphs the router's plan fetches from, in its order.
  def services(result)
    plan = result.dig('extensions', 'apolloQueryPlan', 'object')
    collect = lambda do |node|
      case node
      when Hash then (node['kind'] == 'Fetch' ? [node['serviceName']] : []) + node.values.flat_map(&collect)
      when Array then node.flat_map(&collect)
      else []
      end
    end
    collect.call(plan)
  end

  def planned(query, variables = {}, token: nil)
    router(token: token, headers: { 'Apollo-Expose-Query-Plan' => 'true' }).execute(query, variables: variables)
  end

  describe 'User, an entity of accounts the blog adds to' do
    it 'resolves accounts fields and the blog fields of each user, @hasMany batched in _entities' do
      grace = sign_up(name: 'Grace Hopper')
      2.times { write_post(ada) }
      write_post(grace, title: 'COBOL')

      result = planned('query($name: String) { users(name: $name, first: 50) { data { name posts { title } } paginatorInfo { total } } }',
                       { name: '%' })
      users = data(result).dig('users', 'data').to_h { |user| [user['name'], user['posts'].size] }

      expect(users).to include('Ada Lovelace' => 2, 'Grace Hopper' => 1)
      expect(services(result)).to eq(%w[accounts blog])
    end

    it "answers the blog's Post.author with accounts' fields: email only for the user themselves (@canRoot)" do
      id = write_post(ada, title: 'Notes')
      query = 'query($id: ID!) { post(id: $id) { title author { id name email role } } }'

      own = data(router(token: ada[:token]).execute(query, variables: { id: id }))
      guest = router.execute(query, variables: { id: id })

      expect(own['post']).to eq('title' => 'Notes',
                                'author' => { 'id' => ada[:id], 'name' => 'Ada Lovelace', 'email' => ada[:email],
                                              'role' => 'MEMBER' })
      expect(guest.dig('data', 'post', 'author', 'email')).to be_nil
      expect(messages(guest)).to eq(['This action is unauthorized.'])
    end

    it '@override: postsCount, which accounts declared first, is the blog\'s now' do
      3.times { write_post(ada) }

      result = planned('query($id: ID!) { user(id: $id) { postsCount } }', { id: ada[:id] })

      expect(data(result)).to eq('user' => { 'postsCount' => 3 })
      expect(services(result)).to eq(%w[accounts blog])
    end

    it '@requires: the router sends the name accounts holds, which the blog signs with' do
      write_post(ada)

      result = planned('query($id: ID!) { user(id: $id) { signature } }', { id: ada[:id] })

      expect(data(result)).to eq('user' => { 'signature' => 'Ada Lovelace · 1 post' })
      expect(services(result)).to eq(%w[accounts blog])
    end

    it "@provides: a comment's author name comes from the blog, with no fetch from accounts" do
      id = write_post(ada)
      router(token: ada[:token]).execute('mutation($id: ID!) { addComment(postId: $id, body: "First!") { id } }', variables: { id: id })

      result = planned('query($id: ID!) { post(id: $id) { comments { data { body author { name } } } } }', { id: id })

      expect(data(result).dig('post', 'comments', 'data')).to eq([{ 'body' => 'First!', 'author' => { 'name' => 'Ada Lovelace' } }])
      expect(services(result)).to eq(%w[blog])
    end

    it 'the signed-in user (@guard), with the token the router passes on to both subgraphs' do
      write_post(ada)

      result = data(router(token: ada[:token]).execute('{ me { email postsCount } }'))

      expect(result).to eq('me' => { 'email' => ada[:email], 'postsCount' => 1 })
    end
  end

  describe 'Authored, an entity interface of the blog that accounts extends (@interfaceObject)' do
    it "resolves accounts' likes on the blog's posts and comments" do
      grace = sign_up(name: 'Grace Hopper')
      post_id = write_post(ada, title: 'Liked')
      comment_id = router(token: ada[:token]).execute('mutation($id: ID!) { addComment(postId: $id, body: "Me too") { id } }',
                                                      variables: { id: post_id }).dig('data', 'addComment', 'id')
      [post_id, comment_id].each do |id|
        data(router(token: grace[:token]).execute('mutation($id: ID!) { like(id: $id) { id } }', variables: { id: id }))
      end

      result = planned('{ latestActivity(first: 50) { __typename id likesCount likedBy { name } ... on Post { title } } }')
      activity = data(result)['latestActivity'].select { |item| [post_id, comment_id].include?(item['id']) }

      expect(activity).to contain_exactly(
        { '__typename' => 'Post', 'id' => post_id, 'title' => 'Liked', 'likesCount' => 1, 'likedBy' => [{ 'name' => 'Grace Hopper' }] },
        { '__typename' => 'Comment', 'id' => comment_id, 'likesCount' => 1, 'likedBy' => [{ 'name' => 'Grace Hopper' }] }
      )
      expect(services(result)).to eq(%w[blog accounts])
    end

    it "answers accounts' like mutation with the blog's fields of what was liked" do
      post_id = write_post(ada, title: 'Like me')

      result = router(token: ada[:token]).execute(
        'mutation($id: ID!) { like(id: $id) { __typename likesCount ... on Post { title author { name } } } }', variables: { id: post_id }
      )

      expect(data(result)).to eq('like' => { '__typename' => 'Post', 'likesCount' => 1, 'title' => 'Like me',
                                             'author' => { 'name' => 'Ada Lovelace' } })
    end
  end

  describe 'contexts (@context, @fromContext)' do
    it "fills ReadingTime.caption's argument with the title of its post" do
      id = write_post(ada, title: 'Long read', body: 'word ' * 450)

      result = planned('query($id: ID!) { post(id: $id) { readingTime { minutes caption } } }', { id: id })

      expect(data(result)).to eq('post' => { 'readingTime' => { 'minutes' => 3, 'caption' => 'Long read: 3 min read' } })
      expect(services(result)).to eq(%w[blog blog])
    end
  end

  describe 'unions and nodes across subgraphs' do
    it "answers the blog's search union with users, whose name accounts resolves" do
      name = "Searchable #{SecureRandom.hex(3)}"
      sign_up(name: name)

      result = data(router.execute('query($term: String!) { search(term: $term) { __typename ... on User { name } } }',
                                   variables: { term: name }))

      expect(result['search']).to eq([{ '__typename' => 'User', 'name' => name }])
    end

    it 'finds a tag, a Relay node, by its global id' do
      post_id = write_post(ada, tags: ["federation-#{SecureRandom.hex(3)}"])
      tag = data(router.execute('query($id: ID!) { post(id: $id) { tags { id name } } }', variables: { id: post_id })).dig('post', 'tags', 0)

      result = data(router.execute('query($id: ID!) { node(id: $id) { ... on Tag { name } } }', variables: { id: tag['id'] }))

      expect(result).to eq('node' => { 'name' => tag['name'] })
    end
  end

  describe '@inaccessible' do
    it 'keeps a field, an enum value and their types out of the API the router serves' do
      result = router.execute('{ users(first: 1) { data { internalNotes } } }')
      introspection = data(router.execute('{ __type(name: "Role") { enumValues { name } } }'))

      expect(messages(result).join).to include('internalNotes')
      expect(introspection.dig('__type', 'enumValues').map { |value| value['name'] }).to contain_exactly('MEMBER', 'ADMIN')
    end
  end
end
