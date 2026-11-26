# frozen_string_literal: true

# The same graph through GraphQL Yoga (gateway/): the supergraph stitched by
# @graphql-tools/federation, @interfaceObject added by gateway/src/interface-objects.js.
# Yoga asks the subgraphs for queries and mutations with POSTs, and for
# subscriptions with a GET that accepts `text/event-stream`, which Lighthouse
# answers over Server-Sent Events.
RSpec.describe 'Federation through GraphQL Yoga', if: Stack.yoga? do
  let(:ada) { sign_up(name: 'Ada Lovelace') }

  describe 'entities across the subgraphs' do
    it 'resolves accounts fields and the blog fields of each user' do
      grace = sign_up(name: 'Grace Hopper')
      2.times { write_post(ada) }
      write_post(grace, title: 'COBOL')

      result = data(yoga.execute('query($name: String) { users(name: $name, first: 50) { data { name posts { title } } } }',
                                 variables: { name: '%' }))
      users = result.dig('users', 'data').to_h { |user| [user['name'], user['posts'].size] }

      expect(users).to include('Ada Lovelace' => 2, 'Grace Hopper' => 1)
    end

    it "answers the blog's Post.author with accounts' fields, the token passed on to both" do
      id = write_post(ada, title: 'Notes')
      query = 'query($id: ID!) { post(id: $id) { title author { name email } } }'

      own = data(yoga(token: ada[:token]).execute(query, variables: { id: id }))
      guest = yoga.execute(query, variables: { id: id })

      expect(own['post']).to eq('title' => 'Notes', 'author' => { 'name' => 'Ada Lovelace', 'email' => ada[:email] })
      expect(guest.dig('data', 'post', 'author', 'email')).to be_nil
      expect(messages(guest)).to eq(['This action is unauthorized.'])
    end

    it '@requires and @override: the blog signs with the name accounts holds, and counts the posts' do
      write_post(ada)

      result = data(yoga.execute('query($id: ID!) { user(id: $id) { postsCount signature } }', variables: { id: ada[:id] }))

      expect(result).to eq('user' => { 'postsCount' => 1, 'signature' => 'Ada Lovelace · 1 post' })
    end

    it "@provides: a comment's author name, from the blog" do
      id = write_post(ada)
      yoga(token: ada[:token]).execute('mutation($id: ID!) { addComment(postId: $id, body: "First!") { id } }', variables: { id: id })

      result = data(yoga.execute('query($id: ID!) { post(id: $id) { comments { data { body author { name } } } } }', variables: { id: id }))

      expect(result.dig('post', 'comments', 'data')).to eq([{ 'body' => 'First!', 'author' => { 'name' => 'Ada Lovelace' } }])
    end
  end

  describe 'Authored, which accounts extends as an @interfaceObject' do
    it "resolves accounts' likes on the blog's posts and comments" do
      grace = sign_up(name: 'Grace Hopper')
      post_id = write_post(ada, title: 'Liked')
      comment_id = yoga(token: ada[:token]).execute('mutation($id: ID!) { addComment(postId: $id, body: "Me too") { id } }',
                                                    variables: { id: post_id }).dig('data', 'addComment', 'id')
      [post_id, comment_id].each do |id|
        data(yoga(token: grace[:token]).execute('mutation($id: ID!) { like(id: $id) { id } }', variables: { id: id }))
      end

      result = data(yoga.execute('{ latestActivity(first: 50) { __typename id likesCount likedBy { name } ... on Post { title } } }'))
      activity = result['latestActivity'].select { |item| [post_id, comment_id].include?(item['id']) }

      expect(activity).to contain_exactly(
        { '__typename' => 'Post', 'id' => post_id, 'title' => 'Liked', 'likesCount' => 1, 'likedBy' => [{ 'name' => 'Grace Hopper' }] },
        { '__typename' => 'Comment', 'id' => comment_id, 'likesCount' => 1, 'likedBy' => [{ 'name' => 'Grace Hopper' }] }
      )
    end

    it "answers accounts' like mutation with the blog's fields of what was liked" do
      post_id = write_post(ada, title: 'Like me')

      result = yoga(token: ada[:token]).execute(
        'mutation($id: ID!) { like(id: $id) { __typename likesCount ... on Post { title author { name } } } }', variables: { id: post_id }
      )

      expect(data(result)).to eq('like' => { '__typename' => 'Post', 'likesCount' => 1, 'title' => 'Like me',
                                             'author' => { 'name' => 'Ada Lovelace' } })
    end
  end

  describe 'the rest of the supergraph' do
    it 'answers unions across the subgraphs and Relay nodes' do
      name = "Searchable #{SecureRandom.hex(3)}"
      sign_up(name: name)
      post_id = write_post(ada, tags: ["federation-#{SecureRandom.hex(3)}"])
      tag = data(yoga.execute('query($id: ID!) { post(id: $id) { tags { id name } } }', variables: { id: post_id })).dig('post', 'tags', 0)

      search = data(yoga.execute('query($term: String!) { search(term: $term) { __typename ... on User { name } } }', variables: { term: name }))
      node = data(yoga.execute('query($id: ID!) { node(id: $id) { ... on Tag { name } } }', variables: { id: tag['id'] }))

      expect(search['search']).to eq([{ '__typename' => 'User', 'name' => name }])
      expect(node).to eq('node' => { 'name' => tag['name'] })
    end

    it 'keeps @inaccessible fields and enum values out of its API' do
      result = yoga.execute('{ users(first: 1) { data { internalNotes } } }')
      introspection = data(yoga.execute('{ __type(name: "Role") { enumValues { name } } }'))

      expect(messages(result).join).to include('internalNotes')
      expect(introspection.dig('__type', 'enumValues').map { |value| value['name'] }).to contain_exactly('MEMBER', 'ADMIN')
    end

    # @graphql-tools/federation does not run contexts: the gateway leaves
    # @fromContext arguments out, and the subgraph answers without them.
    it 'leaves @fromContext arguments out (Apollo Router fills them)' do
      id = write_post(ada, title: 'Long read', body: 'word ' * 450)

      result = data(yoga.execute('query($id: ID!) { post(id: $id) { readingTime { caption } } }', variables: { id: id }))

      expect(result.dig('post', 'readingTime', 'caption')).to eq('This post: 3 min read')
    end
  end

  # Yoga streams to its clients over SSE, and subscribes to the blog over SSE:
  # the broadcast of a mutation reaches the blog's stream, and Yoga resolves the
  # accounts fields of each update.
  describe 'subscriptions over Server-Sent Events' do
    let(:streams) { [] }

    after { streams.each(&:close) }

    def subscribe(query, variables: {}, token: nil)
      EventStream.new(Stack.yoga_url, query, variables: variables, token: token).tap do |stream|
        streams << stream
        sleep 1 # until the blog has the subscription
      end
    end

    def publish(user, title:)
      id = write_post(user, title: title, published: false)
      yoga(token: user[:token]).execute('mutation($id: ID!) { publishPost(id: $id) { id } }', variables: { id: id })
    end

    it 'delivers each broadcast, with the fields of both subgraphs' do
      stream = subscribe('subscription { postPublished { title author { name } } }')

      publish(ada, title: 'Live')
      publish(ada, title: 'Again')

      expect([stream.next_result, stream.next_result]).to eq(
        [{ 'data' => { 'postPublished' => { 'title' => 'Live', 'author' => { 'name' => 'Ada Lovelace' } } } },
         { 'data' => { 'postPublished' => { 'title' => 'Again', 'author' => { 'name' => 'Ada Lovelace' } } } }]
      )
    end

    it "filters the updates by each subscriber's arguments" do
      grace = sign_up(name: 'Grace Hopper')
      stream = subscribe('subscription($author: ID) { postPublished(authorId: $author) { title } }', variables: { author: ada[:id] })

      publish(grace, title: 'Not for me')
      publish(ada, title: 'For me')

      expect(stream.next_result).to eq('data' => { 'postPublished' => { 'title' => 'For me' } })
    end

    it 'passes the token on: a subscription its class authorizes only for a signed-in user' do
      signed_in = subscribe('subscription { postCreated { title } }', token: ada[:token])
      guest = subscribe('subscription { postCreated { title } }')

      write_post(ada, title: 'Fresh')

      expect(signed_in.next_result).to eq('data' => { 'postCreated' => { 'title' => 'Fresh' } })
      expect(guest.next_result['errors'].map { |error| error['message'] }).to eq(['Sign in to subscribe to new posts.'])
    end
  end
end
