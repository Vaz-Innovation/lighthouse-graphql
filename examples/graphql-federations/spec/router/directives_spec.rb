# frozen_string_literal: true

# Lighthouse's directives, in each subgraph, as a client of the router uses them:
# pagination, filters, ordering, search, caching, authorization, validation and
# mutations, with their errors reaching the client as the subgraph answers them.
RSpec.describe "Lighthouse's directives through Apollo Router" do
  let(:ada) { sign_up(name: 'Ada Lovelace') }

  describe 'queries' do
    it '@paginate: a paginator and a Relay connection, from each subgraph' do
      sign_up(name: 'Grace Hopper')
      3.times { write_post(ada) }

      users = data(router.execute('{ users(first: 2, page: 1) { data { id } paginatorInfo { count perPage currentPage hasMorePages } } }'))
      feed = data(router.execute('{ feed(first: 2) { edges { cursor node { title author { name } } } pageInfo { hasNextPage endCursor } } }'))

      expect(users.dig('users', 'paginatorInfo')).to include('count' => 2, 'perPage' => 2, 'currentPage' => 1)
      expect(feed.dig('feed', 'edges').size).to eq(2)
      expect(feed.dig('feed', 'edges').first.dig('node', 'author')).to have_key('name')
      expect(feed.dig('feed', 'pageInfo', 'hasNextPage')).to be(true)
    end

    it '@whereConditions, @orderBy and @search on the blog, the authors from accounts' do
      marker = SecureRandom.hex(4)
      %w[Bravo Alpha Charlie].each { |word| write_post(ada, title: "#{word} #{marker}") }

      result = data(router.execute(<<~GRAPHQL, variables: { pattern: "%#{marker}%" }))
        query($pattern: Mixed) {
          posts(where: { column: TITLE, operator: LIKE, value: $pattern }, orderBy: [{ column: TITLE, order: ASC }], first: 10) {
            data { title author { name } }
          }
        }
      GRAPHQL
      searched = data(router.execute('query($term: String) { posts(search: $term, first: 5) { data { title } } }',
                                     variables: { term: "Charlie #{marker}" }))

      expect(result.dig('posts', 'data').map { |post| post['title'] }).to eq(%W[Alpha\ #{marker} Bravo\ #{marker} Charlie\ #{marker}])
      expect(result.dig('posts', 'data').map { |post| post.dig('author', 'name') }.uniq).to eq(['Ada Lovelace'])
      expect(searched.dig('posts', 'data').first['title']).to eq("Charlie #{marker}")
    end

    it '@orderBy and @like on accounts, @guard on the blog with the token the router passes on' do
      write_post(ada, title: 'Mine', published: false)

      mine = data(router(token: ada[:token]).execute('{ myPosts(title: "Mi%") { title published } }'))
      guest = router.execute('{ myPosts { title } }')
      users = data(router.execute('query($name: String) { users(name: $name, orderBy: [{ column: CREATED_AT, order: DESC }]) { data { id } } }',
                                  variables: { name: ada[:name] }))

      expect(mine['myPosts']).to eq([{ 'title' => 'Mine', 'published' => false }])
      expect(messages(guest)).to eq(['Unauthenticated.'])
      expect(users.dig('users', 'data').first['id']).to eq(ada[:id])
    end

    it '@cache and @clearCache: the tag list, cached by the blog, cleared by createTag' do
      before = data(router.execute('{ tags { name } }'))['tags']
      name = "fresh-#{SecureRandom.hex(3)}"
      data(router(token: ada[:token]).execute('mutation($name: String!) { createTag(name: $name) { name } }', variables: { name: name }))

      after = data(router.execute('{ tags { name } }'))['tags']

      expect(after.map { |tag| tag['name'] }).to eq(before.map { |tag| tag['name'] } + [name])
    end

    it "@count, @method, @hasMany(type: PAGINATOR) and a type class's method, on posts the router fetches" do
      id = write_post(ada, title: 'Counted', body: 'one two three four five')
      router(token: ada[:token]).execute('mutation($id: ID!) { addComment(postId: $id, body: "Nice") { id } }', variables: { id: id })

      query = 'query($id: ID!) { post(id: $id) { summary(words: 2) commentsCount ' \
              'comments(first: 1) { paginatorInfo { total } } readingTime { words } } }'
      result = data(router.execute(query, variables: { id: id }))

      expect(result['post']).to eq('summary' => 'one two', 'commentsCount' => 1, 'comments' => { 'paginatorInfo' => { 'total' => 1 } },
                                   'readingTime' => { 'words' => 5 })
    end
  end

  describe 'mutations' do
    it '@validator: accounts refuses an invalid sign-up, with the validation errors the client gets' do
      result = router.execute('mutation { signUp(name: "", email: "nope") { id } }')

      expect(result['errors'].first['extensions']).to include('validation' => include('name' => ['must be filled'],
                                                                                      'email' => ['is not an email address']))
    end

    it '@create with a nested mutation, @canModel, @inject, and the author resolved by accounts' do
      tag = "nested-#{SecureRandom.hex(3)}"

      result = data(router(token: ada[:token]).execute(<<~GRAPHQL, variables: { tag: tag }))
        mutation($tag: String!) {
          createPost(input: { title: "Tagged", published: true, tags: { create: [{ name: $tag }] } }) {
            title tags { name } author { name }
          }
        }
      GRAPHQL

      expect(result['createPost']).to eq('title' => 'Tagged', 'tags' => [{ 'name' => tag }], 'author' => { 'name' => 'Ada Lovelace' })
    end

    it "@canFind: only a post's author (or an admin) may change it" do
      id = write_post(ada, title: 'Original')
      grace = sign_up(name: 'Grace Hopper')
      admin = sign_up(name: 'Admin', admin: true)
      update = 'mutation($id: ID!, $title: String!) { updatePost(input: { id: $id, title: $title }) { title } }'

      denied = router(token: grace[:token]).execute(update, variables: { id: id, title: 'Hijacked' })
      allowed = data(router(token: admin[:token]).execute(update, variables: { id: id, title: 'Edited' }))

      expect(messages(denied)).to eq(['This action is unauthorized.'])
      expect(allowed).to eq('updatePost' => { 'title' => 'Edited' })
    end

    it 'publishPost (a convention mutation), then deletePost (@delete)' do
      id = write_post(ada, title: 'Draft', published: false)
      user = sign_up(name: 'Grace Hopper')
      publish = 'mutation($id: ID!) { publishPost(id: $id) { published } }'

      expect(data(router(token: ada[:token]).execute(publish, variables: { id: id }))).to eq('publishPost' => { 'published' => true })
      expect(messages(router(token: ada[:token]).execute(publish, variables: { id: id }))).to eq(['This post is already published.'])
      expect(messages(router(token: user[:token]).execute('mutation($id: ID!) { deletePost(id: $id) { id } }', variables: { id: id })))
        .to eq(['This action is unauthorized.'])
      expect(data(router(token: ada[:token]).execute('mutation($id: ID!) { deletePost(id: $id) { title } }', variables: { id: id })))
        .to eq('deletePost' => { 'title' => 'Draft' })
    end
  end
end
