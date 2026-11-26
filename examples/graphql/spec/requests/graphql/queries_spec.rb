require 'rails_helper'

RSpec.describe 'GraphQL queries', type: :request do
  describe '@find' do
    it 'returns the user an argument identifies, or null' do
      user = create(:user, name: 'Ada Lovelace')

      expect(graphql("{ user(id: #{user.id}) { id name } }")).to eq('data' => { 'user' => { 'id' => user.id.to_s, 'name' => 'Ada Lovelace' } })
      expect(graphql('{ user(id: 0) { id } }')).to eq('data' => { 'user' => nil })
    end
  end

  describe '@paginate' do
    before { %w[Carol Alice Bob].each { |name| create(:user, name: name) } }

    it 'pages through users with a full paginatorInfo' do
      body = graphql('{ users(first: 2, page: 2) { data { name } paginatorInfo { total currentPage lastPage hasMorePages count } } }')

      expect(body.dig('data', 'users')).to eq(
        'data' => [{ 'name' => 'Bob' }],
        'paginatorInfo' => { 'total' => 3, 'currentPage' => 2, 'lastPage' => 2, 'hasMorePages' => false, 'count' => 1 }
      )
    end

    it 'uses defaultCount when the client omits first, and sorts with @orderBy' do
      body = graphql('{ users(orderBy: [{ column: NAME, order: DESC }]) { data { name } paginatorInfo { perPage } } }')

      expect(body.dig('data', 'users', 'data').pluck('name')).to eq(%w[Carol Bob Alice])
      expect(body.dig('data', 'users', 'paginatorInfo', 'perPage')).to eq(10)
    end

    it 'filters with @like' do
      body = graphql('{ users(name: "li") { data { name } } }')

      expect(body.dig('data', 'users', 'data')).to eq([{ 'name' => 'Alice' }])
    end
  end

  describe '@orderBy and @whereHasConditions on users' do
    let!(:authors) { %w[Carol Alice Bob].index_with { |name| create(:user, name: name) } }

    before do
      create_list(:post, 2, author: authors['Bob'])
      create(:post, :draft, author: authors['Carol'])
    end

    it 'orders by how many posts each user wrote, then by name' do
      body = graphql('{ users(orderBy: [{ posts: { aggregate: COUNT }, order: DESC }, { column: NAME, order: ASC }]) { data { name } } }')

      expect(body.dig('data', 'users', 'data').pluck('name')).to eq(%w[Bob Carol Alice])
    end

    it 'keeps the users with a post matching the condition' do
      body = graphql('{ users(hasPosts: { column: PUBLISHED, value: false }) { data { name } } }')

      expect(body.dig('data', 'users', 'data')).to eq([{ 'name' => 'Carol' }])
    end

    it 'keeps the users with any post for {}' do
      body = graphql('{ users(hasPosts: {}, orderBy: [{ column: NAME, order: ASC }]) { data { name } } }')

      expect(body.dig('data', 'users', 'data').pluck('name')).to eq(%w[Bob Carol])
    end
  end

  describe '@builder and @orderBy on the field' do
    it 'lists only published posts, newest first' do
      older = create(:post, title: 'Older', created_at: 2.days.ago)
      newer = create(:post, title: 'Newer', created_at: 1.day.ago)
      create(:post, :draft, title: 'Draft')

      body = graphql('{ posts { data { id title } paginatorInfo { total } } }')

      expect(body.dig('data', 'posts', 'data')).to eq([{ 'id' => newer.id.to_s, 'title' => 'Newer' },
                                                       { 'id' => older.id.to_s, 'title' => 'Older' }])
      expect(body.dig('data', 'posts', 'paginatorInfo', 'total')).to eq(2)
    end

    it "orders by the client's orderBy first, then newest first" do
      b = create(:post, title: 'B', created_at: 3.days.ago)
      older_a = create(:post, title: 'A', created_at: 2.days.ago)
      newer_a = create(:post, title: 'A', created_at: 1.day.ago)

      body = graphql('{ posts(orderBy: [{ column: TITLE, order: ASC }]) { data { id } } }')

      expect(body.dig('data', 'posts', 'data').pluck('id')).to eq([newer_a, older_a, b].map { |post| post.id.to_s })
    end

    it "orders by the count of each post's comments" do
      quiet = create(:post, title: 'Quiet')
      busy = create(:post, title: 'Busy')
      create_list(:comment, 2, post: busy)
      create(:comment, post: quiet)

      body = graphql('{ posts(orderBy: [{ comments: { aggregate: COUNT }, order: DESC }]) { data { title } } }')

      expect(body.dig('data', 'posts', 'data').pluck('title')).to eq(%w[Busy Quiet])
    end

    it 'leaves drafts out of @find through its scopes' do
      draft = create(:post, :draft)

      expect(graphql("{ post(id: #{draft.id}) { title } }")).to eq('data' => { 'post' => nil })
    end
  end

  describe '@whereConditions' do
    it 'combines client-built conditions with the field builder' do
      ada = create(:user)
      create(:post, title: 'GraphQL in Rails', author: ada)
      create(:post, title: 'GraphQL elsewhere')
      create(:post, :draft, title: 'GraphQL draft', author: ada)

      body = graphql(<<~GRAPHQL)
        {
          posts(where: { AND: [{ column: TITLE, operator: LIKE, value: "GraphQL%" }, { column: AUTHOR_ID, value: #{ada.id} }] }) {
            data { title }
          }
        }
      GRAPHQL

      expect(body.dig('data', 'posts', 'data')).to eq([{ 'title' => 'GraphQL in Rails' }])
    end
  end

  describe 'a Relay connection' do
    it 'pages with cursors' do
      posts = Array.new(3) { |i| create(:post, created_at: i.days.ago) }

      first = graphql('{ feed(first: 2) { edges { cursor node { id } } pageInfo { hasNextPage endCursor total } } }').dig('data', 'feed')
      rest = graphql("{ feed(first: 2, after: \"#{first.dig('pageInfo', 'endCursor')}\") { edges { node { id } } pageInfo { hasNextPage } } }")

      expect(first['edges'].map { |edge| edge.dig('node', 'id') }).to eq(posts.first(2).map { |post| post.id.to_s })
      expect(first['pageInfo']).to include('hasNextPage' => true, 'total' => 3)
      expect(rest.dig('data', 'feed', 'edges')).to eq([{ 'node' => { 'id' => posts.last.id.to_s } }])
      expect(rest.dig('data', 'feed', 'pageInfo', 'hasNextPage')).to be(false)
    end
  end

  describe '@count' do
    it 'counts a model through a scope' do
      create_list(:post, 2)
      create(:post, :draft)

      expect(graphql('{ publishedPostCount }')).to eq('data' => { 'publishedPostCount' => 2 })
    end
  end

  describe 'a Resolvers:: class' do
    it 'resolves Query.searchPosts by convention' do
      create(:post, title: 'Caching GraphQL responses')
      create(:post, body: 'All about caching.', title: 'Other')
      create(:post, :draft, title: 'Caching drafts')
      create(:post, title: 'Unrelated')

      body = graphql('query Search($term: String!) { searchPosts(term: $term) { title } }', variables: { term: 'caching' })

      expect(body.dig('data', 'searchPosts').pluck('title')).to contain_exactly('Caching GraphQL responses', 'Other')
    end
  end
end
