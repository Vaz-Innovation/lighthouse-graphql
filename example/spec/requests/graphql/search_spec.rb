require 'rails_helper'

# @search on the engines it runs through, each in its own group:
#
# - Searchkick, against OpenSearch or Elasticsearch, when OPENSEARCH_URL is set;
# - pg_search, in PostgreSQL, when DATABASE_URL is a PostgreSQL one.
#
#   docker run -d -p 9200:9200 -e discovery.type=single-node -e DISABLE_SECURITY_PLUGIN=true \
#     -e DISABLE_INSTALL_DEMO_CONFIG=true opensearchproject/opensearch:2
#   OPENSEARCH_URL=http://127.0.0.1:9200 \
#   DATABASE_URL=postgres://postgres:postgres@127.0.0.1:5433/lighthouse_example_test bundle exec rspec spec/requests/graphql/search_spec.rb
#
# The gem suite runs the same cases against fake engines (spec/lighthouse/search_spec.rb).
# The schemas here are the specs' own, built from SDL over subclasses of the app's models,
# so the app's schema and its SQLite runs know nothing of either engine.
opensearch = ENV['OPENSEARCH_URL'].present?
postgres = ActiveRecord::Base.connection_db_config.adapter.match?(/postg/i)

if opensearch
  require 'opensearch'
  require 'searchkick'
  Searchkick.client = OpenSearch::Client.new(url: ENV.fetch('OPENSEARCH_URL'))

  # Indexed by hand (Searchkick.reindex), as the tests run in a transaction.
  class SearchedPost < Post
    searchkick index_name: 'lighthouse_example_searched_posts', callbacks: false

    def search_data = { title: title, body: body, author_id: author_id, published: published }
  end
end

if postgres
  require 'pg_search'

  class PgSearchedPost < Post
    include PgSearch::Model

    pg_search_scope :search, against: { title: 'A', body: 'B' }, using: { tsearch: { prefix: true } }
    pg_search_scope :search_title, against: :title

    scope :recent, -> { where('posts.created_at > ?', 1.year.ago) }
  end

  class PgSearchedUser < User
    has_many :posts, class_name: 'PgSearchedPost', foreign_key: :author_id, inverse_of: false, dependent: nil
  end
end

RSpec.describe 'GraphQL @search on its engines', type: :request do
  def schema_from(sdl) = Lighthouse::GraphQL::SchemaFactory.build_base_schema(sdl: sdl, schema_options: { using: { GraphQL::Dataloader => {} } })

  def run(schema, query, context = {}) = schema.execute(query, context: context).to_h

  # The titles of a list, or of a page's data.
  def titles(result, field = 'posts')
    rows = result.dig('data', field)
    (rows.is_a?(Hash) ? rows['data'] : rows).pluck('title')
  end

  # The SQL statements a block runs, schema introspection and transaction statements aside.
  def sql_in(&)
    sql = []
    callback = lambda { |*, payload|
      sql << payload[:sql] unless payload[:name] == 'SCHEMA' || payload[:sql].match?(/\A(BEGIN|COMMIT|SAVEPOINT|RELEASE|ROLLBACK)/)
    }
    ActiveSupport::Notifications.subscribed(callback, 'sql.active_record', &)
    sql
  end

  describe 'Searchkick', if: opensearch do
    let(:author) { create(:user) }
    let(:other) { create(:user) }
    let(:schema) do
      schema_from(<<~GRAPHQL)
        type User { id: ID! name: String! }
        type SearchedPost {
          id: ID!
          title: String!
          author: User! @belongsTo
        }
        type Query {
          posts(search: String @search, authorId: Int @eq(key: "author_id")): [SearchedPost!]! @all
          paged(search: String @search, authorId: Int @eq(key: "author_id")): [SearchedPost!]! @paginate
          feed(search: String @search): [SearchedPost!]! @paginate(type: CONNECTION)
          indexed(search: String @search(within: "lighthouse_example_searched_posts")): [SearchedPost!]! @all
          filtered(search: String @search, title: String @neq): [SearchedPost!]! @all
        }
      GRAPHQL
    end

    before do
      create(:post, author: author, title: 'Great title', body: 'one')
      create(:post, author: author, title: 'Really great great title', body: 'great')
      create(:post, author: other, title: 'Another great one', body: 'two')
      create(:post, author: other, title: 'Bad title', body: 'three')
      SearchedPost.reindex
      SearchedPost.search_index.refresh
    end

    def requests_in
      requests = []
      subscriber = ActiveSupport::Notifications.subscribe('search.searchkick') { |*| requests << true }
      yield
      requests.size
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    it 'returns the posts in the order of their relevance' do
      result = run(schema, '{ posts(search: "great") { title } }')

      expect(titles(result)).to eq(['Really great great title', 'Great title', 'Another great one'])
    end

    it 'narrows the search with @eq, as a filter in the engine' do
      result = run(schema, "{ posts(search: \"great\", authorId: #{other.id}) { title } }")

      expect(titles(result)).to eq(['Another great one'])
    end

    it 'does not search without the argument' do
      expect(titles(run(schema, '{ posts { title } }')).size).to eq(4)
    end

    it 'pages with the total of the same request' do
      query = '{ paged(first: 2, page: 2, search: "great") { data { title } paginatorInfo { total lastPage currentPage hasMorePages } } }'
      result = nil
      requests = requests_in { result = run(schema, query) }

      expect(result.dig('data', 'paged')).to eq(
        'data' => [{ 'title' => 'Another great one' }],
        'paginatorInfo' => { 'total' => 3, 'lastPage' => 2, 'currentPage' => 2, 'hasMorePages' => false }
      )
      expect(requests).to eq(1)
    end

    it 'counts without a page, which Scout cannot' do
      result = run(schema, '{ paged(first: 0, search: "great") { data { title } paginatorInfo { total } } }')

      expect(result.dig('data', 'paged')).to eq('data' => [], 'paginatorInfo' => { 'total' => 3 })
    end

    it 'walks a connection by position' do
      page = '{ feed(first: 2, %s search: "great") { edges { node { title } } pageInfo { hasNextPage endCursor total } } }'
      first = run(schema, format(page, '')).dig('data', 'feed')
      second = run(schema, format(page, "after: #{first.dig('pageInfo', 'endCursor').to_json},")).dig('data', 'feed')

      expect(first['edges'].map { |edge| edge.dig('node', 'title') }).to eq(['Really great great title', 'Great title'])
      expect(first['pageInfo']).to include('hasNextPage' => true, 'total' => 3)
      expect(second['edges'].map { |edge| edge.dig('node', 'title') }).to eq(['Another great one'])
    end

    it 'loads the records, and their authors, in one query each' do
      result = nil
      sql = sql_in { result = run(schema, '{ posts(search: "great") { title author { name } } }') }

      expect(result.dig('data', 'posts').size).to eq(3)
      expect(sql.grep(/FROM "posts"/).size).to eq(1)
      expect(sql.grep(/FROM "users"/).size).to eq(1)
    end

    it 'searches the index within: names' do
      expect(titles(run(schema, '{ indexed(search: "bad") { title } }'), 'indexed')).to eq(['Bad title'])
    end

    it 'refuses what an engine cannot apply' do
      result = run(schema, '{ filtered(search: "great", title: "x") { title } }')

      expect(result['errors'].pluck('message')).to eq(['Found arg builder arguments that do not work with @search: @neq on title.'])
    end

    it 'refuses, when the schema is built, what PHP Lighthouse drops silently' do
      expect do
        schema_from('type SearchedPost { id: ID! } type Query { posts(search: String @search): [SearchedPost!]! @all(scopes: ["published"]) }')
      end.to raise_error(Lighthouse::DefinitionError, /Searchkick cannot apply `scopes:`/)
    end
  end

  describe 'pg_search', if: postgres do
    let(:author) { create(:user) }
    let(:other) { create(:user) }
    let(:schema) do
      schema_from(<<~GRAPHQL)
        type PgSearchedUser {
          id: ID!
          name: String!
          posts(search: String @search): [PgSearchedPost!]! @paginate
        }
        type PgSearchedPost {
          id: ID!
          title: String!
          author: PgSearchedUser! @belongsTo
        }
        type Query {
          users: [PgSearchedUser!]! @all
          posts(
            search: String @search
            authorId: Int @eq(key: "author_id")
            where: _ @whereConditions(columns: ["title"])
            orderBy: _ @orderBy(columns: ["title", "id"])
          ): [PgSearchedPost!]! @all
          paged(search: String @search): [PgSearchedPost!]! @paginate(scopes: ["recent"])
          byTitle(search: String @search(within: "search_title")): [PgSearchedPost!]! @all
          mine(search: String @search): [PgSearchedPost!]! @paginate @whereAuth(relation: "author") @orderBy(column: "id", direction: DESC)
        }
      GRAPHQL
    end

    before do
      create(:post, author: author, title: 'Great title', body: 'one')
      create(:post, author: author, title: 'Plain', body: 'great great great')
      create(:post, author: other, title: 'Great great title', body: 'two')
      create(:post, author: other, title: 'Bad title', body: 'three')
    end

    it 'searches in the database, the best rank first' do
      expect(titles(run(schema, '{ posts(search: "great") { title } }'))).to eq(['Great great title', 'Great title', 'Plain'])
    end

    it 'does not search without the argument' do
      expect(titles(run(schema, '{ posts { title } }')).size).to eq(4)
    end

    it 'composes with @eq, @whereConditions and the client order, after the rank' do
      expect(titles(run(schema, "{ posts(search: \"great\", authorId: #{author.id}) { title } }"))).to eq(['Great title', 'Plain'])
      expect(titles(run(schema, '{ posts(search: "great", where: { column: TITLE, operator: NEQ, value: "Plain" }) { title } }')))
        .to eq(['Great great title', 'Great title'])
      by_title = run(schema, '{ posts(search: "great", orderBy: [{ column: TITLE, order: DESC }]) { title } }')
      expect(titles(by_title)).to eq(['Great great title', 'Great title', 'Plain'])
    end

    it 'pages the search: the window, and the total counted on the scope' do
      result = run(schema, '{ paged(first: 2, page: 2, search: "great") { data { title } paginatorInfo { total lastPage } } }')

      expect(result.dig('data', 'paged')).to eq('data' => [{ 'title' => 'Plain' }], 'paginatorInfo' => { 'total' => 3, 'lastPage' => 2 })
    end

    it "applies the field's scopes, @builder and @orderBy, which an engine outside the database cannot" do
      create(:post, author: author, title: 'Great old', created_at: 2.years.ago)

      result = run(schema, '{ paged(first: 10, search: "great") { data { title } paginatorInfo { total } } }')

      expect(titles(result, 'paged')).to eq(['Great great title', 'Great title', 'Plain'])
      expect(result.dig('data', 'paged', 'paginatorInfo', 'total')).to eq(3)
    end

    it 'searches within the pg_search scope that is named' do
      expect(titles(run(schema, '{ byTitle(search: "plain") { title } }'), 'byTitle')).to eq(['Plain'])
    end

    it "keeps @whereAuth, which only lets a user see their own posts, and the field's @orderBy after the rank" do
      result = run(schema, '{ mine(first: 10, search: "great") { data { title } } }', { current_user: author })

      expect(titles(result, 'mine')).to eq(['Great title', 'Plain'])
      expect(titles(run(schema, '{ mine(first: 10, search: "great") { data { title } } }', { current_user: other }), 'mine'))
        .to eq(['Great great title'])
    end

    it 'searches a nested paginated field, batched for every parent with one window query and one count' do
      query = <<~GRAPHQL
        { users { name posts(first: 5, search: "great") { data { title } paginatorInfo { total } } } }
      GRAPHQL
      result = nil
      sql = sql_in { result = run(schema, query) }
      by_name = result.dig('data', 'users').to_h { |user| [user['name'], user['posts']] }

      expect(by_name[author.name]).to eq('data' => [{ 'title' => 'Great title' }, { 'title' => 'Plain' }], 'paginatorInfo' => { 'total' => 2 })
      expect(by_name[other.name]).to eq('data' => [{ 'title' => 'Great great title' }], 'paginatorInfo' => { 'total' => 1 })
      expect(sql.grep(/ROW_NUMBER/).size).to eq(1)
      expect(sql.grep(/GROUP BY/).size).to eq(1)
    end

    it 'finds nothing for a term nothing matches, and for an empty one' do
      expect(titles(run(schema, '{ posts(search: "zzz") { title } }'))).to eq([])
      expect(titles(run(schema, '{ posts(search: "") { title } }'))).to eq([])
    end
  end
end
