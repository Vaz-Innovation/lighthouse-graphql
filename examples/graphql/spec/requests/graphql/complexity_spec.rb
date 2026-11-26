require 'rails_helper'

# AppSchema.max_complexity(1000) refuses a query that scores over it before
# anything runs. The score is graphql-ruby's, from what Lighthouse says each
# field costs: paginated fields scale by `first`, @complexity names an analyzer
# (Analyzers::TagPostsComplexity), and a Resolvers:: class declares its own `complexity`.
RSpec.describe 'GraphQL query complexity', type: :request do
  # The score of each request's query, as BuildExtensionsResponse carries it.
  let(:scores) { [] }

  before do
    Lighthouse::Events.listen(Lighthouse::Events::BuildExtensionsResponse) { |event| (scores << event.query_complexity) && nil }
  end

  after { Lighthouse::Events.reset! }

  describe 'over the limit' do
    let(:query) { '{ posts(first: 100) { data { title comments(first: 50) { data { body } } } } }' }

    it 'is refused before it runs' do
      create(:post)
      body = nil

      statements = sql_queries { body = graphql(query) }

      expect(error_messages(body)).to eq(['Query has complexity of 10301, which exceeds max complexity of 1000'])
      expect(body).not_to have_key('data')
      expect(statements).to be_empty
    end

    it 'still gets a score' do
      graphql(query)

      # comments: 1 + (data 1 + body 1) × 50 = 101; posts: 1 + (data 1 + title 1 + 101) × 100
      expect(scores).to eq([10_301])
    end
  end

  describe 'paginated fields' do
    it 'cost their selection once per item asked for' do
      create(:post, title: 'Hello')

      body = graphql('{ posts(first: 10) { data { title } } }')

      expect(body.dig('data', 'posts', 'data')).to eq([{ 'title' => 'Hello' }])
      expect(scores).to eq([1 + (2 * 10)])
    end

    it 'scale with `first`' do
      graphql('{ posts(first: 100) { data { title } } }')

      expect(scores).to eq([1 + (2 * 100)])
    end

    it 'take the page size when `first` is left out, connections included' do
      graphql('{ posts { data { title } } }')
      graphql('{ feed { edges { node { title } } } }')

      # posts: defaultCount 10; feed: defaultCount 5, over edges { node { title } }
      expect(scores).to eq([1 + (2 * 10), 1 + (3 * 5)])
    end
  end

  it 'costs Tag.posts the complexity of the analyzer its @complexity names' do
    create(:tag, name: 'ruby')

    body = graphql('{ tags { name posts { title } } }')

    expect(AppSchema.query_analyzers).to include(Analyzers::TagPostsComplexity)
    expect(body.dig('data', 'tags')).to eq([{ 'name' => 'ruby', 'posts' => [] }])
    # posts: 1 + title 1 × POSTS_PER_TAG; tags: 1 + name 1 + posts
    expect(scores).to eq([1 + (1 + (1 + (1 * Analyzers::TagPostsComplexity::POSTS_PER_TAG)))])
  end

  it 'costs Query.searchPosts the complexity Resolvers::SearchPosts declares' do
    graphql('{ searchPosts(term: "ruby") { title body } }')

    expect(scores).to eq([1 + (2 * Resolvers::SearchPosts::MAX_RESULTS)])
  end
end
