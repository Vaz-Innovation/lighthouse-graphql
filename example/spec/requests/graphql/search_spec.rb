require 'rails_helper'

# @search, end to end and on each engine:
#
# - the app's own fields, through POST /graphql: Query.posts(search:) on Post's
#   pg_search scope, and Query.searchComments(search:) on Comment's Searchkick index;
# - Searchkick on Elasticsearch 9 and on OpenSearch 3, each started by Testcontainers
#   (spec/search_engines.rb), or the server ELASTICSEARCH_URL / OPENSEARCH_URL names.
#   SEARCH_ENGINES picks them: SEARCH_ENGINES=opensearch runs one, SEARCH_ENGINES= none;
# - pg_search, in the suite's PostgreSQL (spec/postgres_container.rb) or a PostgreSQL
#   DATABASE_URL. CI's MySQL run skips the pg_search groups.
#
# The gem suite runs the same cases against fake engines (spec/lighthouse/search_spec.rb).
# The engines' schemas are the specs' own, built from SDL over subclasses of the app's models.
search_engines = SearchEngines.enabled
postgres = ActiveRecord::Base.connection_db_config.adapter.match?(/postg/i)

# Indexed by hand (reindex), as the specs run in a transaction.
class SearchedPost < Post
  searchkick index_name: 'lighthouse_example_searched_posts', callbacks: false

  # Both gems on one model: `within: "search_title"` searches with pg_search, anything else with Searchkick.
  pg_search_scope :search_title, against: :title

  # A @builder of the spec's own: the posts of these authors, as the engine's where.
  def self.by_authors(target, ids, _context)
    target.options[:where] = { author_id: ids }
    target
  end

  # Query.found, resolved by a class of the app's own: the search, through resolve_info.enhance_builder, two at most.
  def self.found(_object, _args, _context, resolve_info)
    found = resolve_info.enhance_builder(all)
    found.is_a?(Lighthouse::Search::Result) ? found.records(first: 2) : found.limit(2)
  end

  # Pundit's: who may edit it (@canQuery(ability: "update")) is who may edit a post, its author or an admin.
  def self.policy_class = PostPolicy

  def search_data = { title: title, body: body, author_id: author_id, published: published }
end

if postgres
  class PgSearchedPost < Post
    include PgSearch::Model

    pg_search_scope :search, against: { title: 'A', body: 'B' }, using: { tsearch: { prefix: true } }
    pg_search_scope :search_title, against: :title

    scope :recent, -> { where('posts.created_at > ?', 1.year.ago) }
  end

  # A default order, which a search sorts by rank before.
  class PgOrderedPost < PgSearchedPost
    default_scope { order(title: :desc) }
  end

  class PgSearchedUser < User
    has_many :posts, class_name: 'PgSearchedPost', foreign_key: :author_id, inverse_of: false, dependent: nil
  end
end

RSpec.describe 'GraphQL @search', type: :request do
  def schema_from(sdl) = Lighthouse::GraphQL::SchemaFactory.build_base_schema(sdl: sdl, schema_options: { using: { GraphQL::Dataloader => {} } })

  def run(schema, query, context = {}) = schema.execute(query, context: context).to_h

  # The titles of a list, or of a page's data.
  def titles(result, field = 'posts')
    rows = result.dig('data', field)
    (rows.is_a?(Hash) ? rows['data'] : rows).pluck('title')
  end

  # Matches SQL that reads `table`, however the database quotes its name: its first FROM, not a subquery's.
  def from(table) = /\A\s*SELECT\b(?:(?!\bFROM\b).)*\bFROM #{Regexp.escape(ActiveRecord::Base.connection.quote_table_name(table))}/m

  # The SQL statements a block runs, schema introspection and transaction statements aside.
  def sql_in(&)
    sql = []
    callback = lambda { |*, payload|
      sql << payload[:sql] unless payload[:name] == 'SCHEMA' || payload[:sql].match?(/\A(BEGIN|COMMIT|SAVEPOINT|RELEASE|ROLLBACK)/)
    }
    ActiveSupport::Notifications.subscribed(callback, 'sql.active_record', &)
    sql
  end

  describe "the app's Query.posts(search:)", if: postgres do
    let(:ada) { create(:user, name: 'Ada') }
    let(:grace) { create(:user, name: 'Grace') }

    def posts(arguments, selection = 'data { title }')
      graphql("{ posts(#{arguments}) { #{selection} } }").dig('data', 'posts')
    end

    def titles(arguments) = posts(arguments)['data'].pluck('title')

    before do
      create(:post, author: ada, title: 'Rails routing', body: 'Resources and constraints.', created_at: 3.days.ago)
      create(:post, author: grace, title: 'Testing', body: 'Request specs for a Rails app.', created_at: 2.days.ago)
      create(:post, author: ada, title: 'Rails caching', body: 'Fragments and keys.', created_at: 1.day.ago)
      create(:post, :draft, author: ada, title: 'Rails drafts', body: 'Not out yet.')
      create(:post, author: grace, title: 'Elixir', body: 'Processes.')
    end

    it "finds the published posts, a title match first and the field's newest-first order between equal ranks" do
      expect(titles('search: "rails"')).to eq(['Rails caching', 'Rails routing', 'Testing'])
    end

    it 'matches a prefix of a word' do
      expect(titles('search: "rail"')).to eq(['Rails caching', 'Rails routing', 'Testing'])
    end

    it 'lists every published post, newest first, without a search' do
      expect(titles('first: 10')).to eq(['Elixir', 'Rails caching', 'Testing', 'Rails routing'])
    end

    it 'narrows the search with @whereConditions' do
      expect(titles(%(search: "rails", where: { column: AUTHOR_ID, value: #{grace.id} }))).to eq(['Testing'])
    end

    it "keeps the rank first, and the client's orderBy between equal ranks" do
      expect(titles('search: "rails", orderBy: [{ column: TITLE, order: ASC }]')).to eq(['Rails caching', 'Rails routing', 'Testing'])
    end

    it 'pages the matches, with their total' do
      page = posts('search: "rails", first: 2, page: 2', 'data { title } paginatorInfo { total lastPage }')

      expect(page).to eq('data' => [{ 'title' => 'Testing' }], 'paginatorInfo' => { 'total' => 3, 'lastPage' => 2 })
    end

    it 'loads what the matches select below them without N+1' do
      body = nil
      sql = sql_in { body = graphql('{ posts(search: "rails") { data { title author { name } } } }') }

      expect(body.dig('data', 'posts', 'data').pluck('author')).to eq([{ 'name' => 'Ada' }, { 'name' => 'Ada' }, { 'name' => 'Grace' }])
      expect(sql.grep(from(:users)).size).to eq(1)
    end

    it 'stays a public, cacheable list' do
      posts('search: "rails"')

      expect(response.headers['Cache-Control']).to eq('max-age=60, public')
    end

    it 'finds nothing for a word no published post has' do
      expect(titles('search: "drafts"')).to eq([])
    end
  end

  SearchEngines::IMAGES.each_key do |engine|
    describe "Searchkick on #{engine}", if: search_engines.include?(engine) do
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
            listed(search: String @search, first: Int, offset: Int): [SearchedPost!]! @all
            paged(search: String @search, authorId: Int @eq(key: "author_id")): [SearchedPost!]! @paginate
            feed(search: String @search): [SearchedPost!]! @paginate(type: CONNECTION)
            indexed(search: String @search(within: "lighthouse_example_searched_posts")): [SearchedPost!]! @all
            filtered(search: String @search, title: String @neq): [SearchedPost!]! @all
            byTitle(search: String @search(within: "search_title")): [SearchedPost!]! @all
            found(search: String @search): [SearchedPost!]! @field(resolver: "SearchedPost@found")
            authored(
              search: String @search
              authors: [Int!] @builder(method: "SearchedPost@by_authors")
              authorId: Int @eq(key: "author_id")
              filters: [SearchedPostFilter!]
            ): [SearchedPost!]! @all
            editable(search: String @search, authorId: Int @eq(key: "author_id")): [SearchedPost!]! @paginate @canQuery(ability: "update")
            best(search: String @search, authorId: Int @eq(key: "author_id")): SearchedPost @first
            only(search: String @search, authorId: Int @eq(key: "author_id")): SearchedPost @find
          }
          input SearchedPostFilter { authorId: Int @eq(key: "author_id") }
        GRAPHQL
      end

      before do
        SearchEngines.use(engine)
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

      it 'never answers a post whose author changed since the index read it for the author it had' do
        Searchkick.callbacks(false) { SearchedPost.find_by!(title: 'Great title').update!(author: other) }

        expect(titles(run(schema, %({ posts(search: "great", authorId: #{author.id}) { title } })))).to eq(['Really great great title'])
      end

      it '@first answers the best match, and the next one when the best is gone from the database' do
        best = ->(arguments) { run(schema, "{ best(#{arguments}) { title } }").dig('data', 'best', 'title') }

        expect(best.call('search: "great"')).to eq('Really great great title')
        expect(best.call(%(search: "great", authorId: #{other.id}))).to eq('Another great one')
        Searchkick.callbacks(false) { SearchedPost.find_by!(title: 'Really great great title').delete }
        expect(best.call('search: "great"')).to eq('Great title')
        expect(best.call('search: "nowhere"')).to be_nil
      end

      it '@find answers the one match, null for none, and an error for more than one' do
        only = run(schema, %({ only(search: "great", authorId: #{other.id}) { title } }))

        expect(only).to eq('data' => { 'only' => { 'title' => 'Another great one' } })
        expect(run(schema, '{ only(search: "nowhere") { title } }')).to eq('data' => { 'only' => nil })
        expect(run(schema, '{ only(search: "great") { title } }')['errors'].pluck('message')).to eq(['The query returned more than one result.'])
      end

      describe 'an index of 10,001 documents within: names' do
        let(:index) { 'lighthouse_example_many_posts' }
        let(:many) do
          schema_from(<<~GRAPHQL)
            type SearchedPost { id: ID! }
            type Query {
              many(search: String @search(within: "#{index}")): [SearchedPost!]! @paginate
              checked(search: String @search(within: "#{index}")): [SearchedPost!]! @paginate @canQuery(ability: "update")
            }
          GRAPHQL
        end

        # Indexed through the client, without rows: what a page finds does not load, only the total counts.
        before do
          client = Searchkick.client
          client.indices.delete(index: index) if client.indices.exists(index: index)
          client.indices.create(index: index, body: { settings: { index: { max_result_window: 20_000 } } })
          client.bulk(index: index, refresh: true, body: Array.new(10_001) { |id| [{ index: { _id: id + 1 } }, { title: 'many' }] }.flatten)
        end

        after { Searchkick.client.indices.delete(index: index) }

        it 'counts every match, past the 10,000 the engine stops at unless asked for the exact total' do
          result = run(many, '{ many(first: 0, search: "*") { paginatorInfo { total } } }')

          expect(result.dig('data', 'many', 'paginatorInfo', 'total')).to eq(10_001)
        end

        it 'refuses @canQuery past the 10,000 matches it checks, which a page could reach' do
          result = run(many, '{ checked(first: 1, search: "*") { paginatorInfo { total } } }', { current_user: author })

          expect(result['errors'].pluck('message'))
            .to eq(['@canQuery checks every record the search finds, at most 10000, and this one finds 10001. Narrow the search.'])
        end

        it "pages as far as the index's own window, which Lighthouse reads from the engine" do
          deep = run(many, '{ many(first: 1, page: 10001, search: "*") { paginatorInfo { total } } }')
          past = run(many, '{ many(first: 10, page: 2001, search: "*") { paginatorInfo { total } } }')

          expect(deep).to eq('data' => { 'many' => { 'paginatorInfo' => { 'total' => 10_001 } } })
          expect(past['errors'].pluck('message')).to eq(
            ['The search reads no further than its first 20000 matches (the index.max_result_window of SearchedPost), so offset 20000 is past ' \
             'them. Narrow the search instead.']
          )
        end
      end

      describe "an index whose own window is smaller than the engines' default" do
        let(:index) { 'lighthouse_example_narrow_posts' }
        let(:narrow) do
          schema_from(<<~GRAPHQL)
            type SearchedPost { id: ID! }
            type Query {
              listed(search: String @search(within: "#{index}")): [SearchedPost!]! @all
              checked(search: String @search(within: "#{index}")): [SearchedPost!]! @paginate @canQuery(ability: "update")
            }
          GRAPHQL
        end

        # Indexed through the client, with ids no row has: what a page finds does not load, only the total counts.
        before do
          client = Searchkick.client
          client.indices.delete(index: index) if client.indices.exists(index: index)
          client.indices.create(index: index, body: { settings: { index: { max_result_window: 50 } } })
          client.bulk(index: index, refresh: true, body: Array.new(60) { |id| [{ index: { _id: 1_000_000 + id } }, { title: 'narrow' }] }.flatten)
        end

        after { Searchkick.client.indices.delete(index: index) }

        it 'reads no further than it, for @all and the records @canQuery checks, and says what @all left unread' do
          listed = run(narrow, '{ listed(search: "*") { id } }')
          checked = run(narrow, '{ checked(first: 1, search: "*") { paginatorInfo { total } } }', { current_user: author })

          expect(listed['errors'].pluck('message')).to eq(
            ['@all answered 50 of the 60 matches the search finds from offset 0: a search reads 10000 at most at once, and no further than ' \
             'its first 50 matches (the index.max_result_window). Use @paginate, or `first` and `offset`, to read the others.']
          )
          expect(checked).to eq('data' => { 'checked' => { 'paginatorInfo' => { 'total' => 60 } } })
        end
      end

      it "reads @all from an offset within the engine's result window, and refuses a page past it" do
        expect(titles(run(schema, '{ listed(search: "great", offset: 1) { title } }'), 'listed')).to eq(['Great title', 'Another great one'])

        result = run(schema, '{ paged(first: 10, page: 1001, search: "great") { data { title } } }')
        expect(result['errors'].pluck('message')).to eq(
          ['The search reads no further than its first 10000 matches (the index.max_result_window of SearchedPost), so offset 10000 is past them. ' \
           'Narrow the search instead.']
        )
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
        expect(sql.grep(from(:posts)).size).to eq(1)
        expect(sql.grep(from(:users)).size).to eq(1)
      end

      it 'searches the index within: names' do
        expect(titles(run(schema, '{ indexed(search: "bad") { title } }'), 'indexed')).to eq(['Bad title'])
      end

      it 'searches with pg_search when within: names a pg_search scope of a model that also calls searchkick', if: postgres do
        expect(titles(run(schema, '{ byTitle(search: "bad") { title } }'), 'byTitle')).to eq(['Bad title'])
      end

      it 'searches a field resolved by a class of your own, through resolve_info.enhance_builder' do
        expect(titles(run(schema, '{ found(search: "great") { title } }'), 'found')).to eq(['Really great great title', 'Great title'])
      end

      it "applies a builder's condition and @eq's on one column both, and every @eq of a list, as the database does" do
        query = '{ authored(search: "great", %s) { title } }'

        expect(titles(run(schema, format(query, "authors: [#{author.id}], authorId: #{other.id}")), 'authored')).to eq([])
        expect(titles(run(schema, format(query, "authors: [#{author.id}, #{other.id}], authorId: #{other.id}")), 'authored'))
          .to eq(['Another great one'])
        expect(titles(run(schema, format(query, "filters: [{ authorId: #{author.id} }, { authorId: #{other.id} }]")), 'authored')).to eq([])
      end

      it "reads the fields an index holds from the engine's mapping, which @trashed falls back on, and its result window from its settings" do
        index = Lighthouse::Search::Searchkick::Index.new
        name = SearchedPost.searchkick_index.name

        expect(index.fields(SearchedPost, name)).to include('title', 'author_id', 'published')
        expect(index.result_window(SearchedPost, name)).to eq(10_000)
      end

      it 'refuses what an engine cannot apply' do
        result = run(schema, '{ filtered(search: "great", title: "x") { title } }')

        expect(result['errors'].pluck('message')).to eq(['Found arg builder arguments that do not work with @search: @neq on title.'])
      end

      it 'checks @canQuery against every post the search finds, not only the page, whose hits then serve the page' do
        query = '{ editable(first: 1, search: "great"%s) { data { title } } }'
        result = nil

        expect(run(schema, format(query, ''), { current_user: author })['errors'].pluck('message')).to eq(['This action is unauthorized.'])
        requests = requests_in { result = run(schema, format(query, ", authorId: #{author.id}"), { current_user: author }) }
        expect(result.dig('data', 'editable', 'data')).to eq([{ 'title' => 'Really great great title' }])
        expect(requests).to eq(1)
      end

      it 'pages the posts @canQuery checked, never one the index gained after the check' do
        grown = false
        subscriber = ActiveSupport::Notifications.subscribe('search.searchkick') do |*|
          next if grown

          grown = true
          SearchedPost.find(create(:post, author: author, title: 'Great new one', body: 'new').id).reindex
          SearchedPost.search_index.refresh
        end
        query = %({ editable(first: 10, search: "great", authorId: #{author.id}) { data { title } } })

        result = run(schema, query, { current_user: author })

        expect(grown).to be(true)
        expect(result.dig('data', 'editable', 'data').pluck('title')).to contain_exactly('Great title', 'Really great great title')
      ensure
        ActiveSupport::Notifications.unsubscribe(subscriber)
      end

      it 'refuses, when the schema is built, what PHP Lighthouse drops silently' do
        expect do
          schema_from('type SearchedPost { id: ID! } type Query { posts(search: String @search): [SearchedPost!]! @all(scopes: ["published"]) }')
        end.to raise_error(Lighthouse::DefinitionError, /Searchkick cannot apply `scopes:`/)
      end

      describe "the app's Query.searchComments(search:)" do
        include ActiveJob::TestHelper

        let(:ada) { create(:user, name: 'Ada') }
        let(:grace) { create(:user, name: 'Grace') }
        let(:engines) { create(:post, author: ada, title: 'Engines') }
        let(:compilers) { create(:post, author: grace, title: 'Compilers') }

        before do
          create(:comment, post: engines, author: grace, body: 'Brilliant work on the engine.')
          create(:comment, post: engines, author: ada, body: 'Thank you, brilliant reader.')
          create(:comment, post: compilers, author: ada, body: 'A brilliant compiler.')
          create(:comment, post: compilers, author: ada, body: 'Nothing to see.')
          create(:comment, post: create(:post, :draft, author: ada), author: grace, body: 'Brilliant draft!')
          reindex_comments
        end

        def reindex_comments
          Comment.reindex
          Comment.search_index.refresh
        end

        def bodies(arguments, as: nil)
          graphql("{ searchComments(#{arguments}) { data { body } } }", as: as).dig('data', 'searchComments', 'data').pluck('body')
        end

        it 'finds the comments on published posts, a typo forgiven' do
          expect(bodies('search: "brillant"'))
            .to contain_exactly('Brilliant work on the engine.', 'Thank you, brilliant reader.', 'A brilliant compiler.')
        end

        it 'narrows the search to a post with postId, a filter in the engine' do
          expect(bodies(%(search: "brilliant", postId: "#{compilers.id}"))).to eq(['A brilliant compiler.'])
        end

        it 'pages the matches, with their total' do
          page = graphql('{ searchComments(search: "brilliant", first: 2, page: 2) { data { body } paginatorInfo { total lastPage } } }')

          expect(page.dig('data', 'searchComments', 'paginatorInfo')).to eq('total' => 3, 'lastPage' => 2)
          expect(page.dig('data', 'searchComments', 'data').size).to eq(1)
        end

        it 'loads what the matches select below them without N+1' do
          body = nil
          sql = sql_in { body = graphql('{ searchComments(search: "brilliant") { data { author { name } post { title } } } }') }

          expect(body.dig('data', 'searchComments', 'data').size).to eq(3)
          expect(sql.grep(from(:users)).size).to eq(1)
          expect(sql.grep(from(:posts)).size).to eq(1)
        end

        it "indexes a draft's comments once it is published, and removes them when it is unpublished" do
          draft = create(:post, :draft, author: ada, title: 'Nanoseconds')
          create(:comment, post: draft, author: grace, body: 'A wire of nanoseconds.')
          reindex_comments
          expect(bodies('search: "nanoseconds"')).to eq([])

          perform_enqueued_jobs { Searchkick.callbacks(true) { graphql("mutation { publishPost(id: #{draft.id}) { id } }", as: ada) } }
          Comment.search_index.refresh
          expect(bodies('search: "nanoseconds"')).to eq(['A wire of nanoseconds.'])

          perform_enqueued_jobs { Searchkick.callbacks(true) { draft.reload.update!(published: false) } }
          Comment.search_index.refresh
          expect(bodies('search: "nanoseconds"')).to eq([])
        end

        it 'never returns a comment whose post is no longer published, before the job removes it from the index' do
          Searchkick.callbacks(true) { compilers.update!(published: false) } # the job is enqueued, not run
          expect(Comment.search('compiler', load: false).map(&:id)).to be_present

          expect(bodies('search: "brilliant"')).to contain_exactly('Brilliant work on the engine.', 'Thank you, brilliant reader.')
        end

        describe 'when hits drop out as they load, mid-page' do
          let(:pages) do
            schema_from(<<~GRAPHQL)
              type Comment { body: String! }
              type Query {
                paginator(search: String @search): [Comment!]! @paginate
                simple(search: String @search): [Comment!]! @paginate(type: SIMPLE)
                connection(search: String @search): [Comment!]! @paginate(type: CONNECTION)
              }
            GRAPHQL
          end
          let(:published) { ['Brilliant work on the engine.', 'Thank you, brilliant reader.', 'A brilliant compiler.'] }

          # Two comments that rank first, on a post unpublished since: the job that drops them from the index has not run.
          before do
            hidden = create(:post, author: ada, title: 'Hidden')
            2.times { create(:comment, post: hidden, author: grace, body: 'Brilliant brilliant brilliant.') }
            reindex_comments
            hidden.update_column(:published, false) # rubocop:disable Rails/SkipsModelValidations -- no callback: the index keeps them.
          end

          def page_of(field, arguments, selection)
            run(pages, %({ #{field}(search: "brilliant", first: 2#{arguments}) { #{selection} } })).dig('data', field)
          end

          it 'walks PAGINATOR pages by position, every comment once' do
            bodies = (1..3).flat_map { |page| page_of('paginator', ", page: #{page}", 'data { body }')['data'].pluck('body') }

            expect(bodies).to match_array(published)
          end

          it 'walks SIMPLE pages while hasMorePages says the engine has more, every comment once' do
            bodies = []
            (1..5).each do |page|
              found = page_of('simple', ", page: #{page}", 'data { body } paginatorInfo { hasMorePages }')
              bodies.concat(found['data'].pluck('body'))
              break unless found.dig('paginatorInfo', 'hasMorePages')
            end

            expect(bodies).to match_array(published)
          end

          it 'walks CONNECTION cursors by engine position, every comment once' do
            bodies = []
            after = ''
            5.times do
              found = page_of('connection', after, 'edges { node { body } } pageInfo { hasNextPage endCursor }')
              bodies.concat(found['edges'].map { |edge| edge.dig('node', 'body') })
              break unless found.dig('pageInfo', 'hasNextPage')

              after = %(, after: "#{found.dig('pageInfo', 'endCursor')}")
            end

            expect(bodies).to match_array(published)
          end
        end

        it 'counts no comment of an unpublished post the index holds, the engine applying search_where' do
          draft_comment = create(:comment, post: create(:post, :draft, author: ada), author: grace, body: 'A brilliant secret.')
          Comment.search_index.store(draft_comment) # past should_index?, as a published flag the index holds
          Comment.search_index.refresh

          page = graphql('{ searchComments(search: "brilliant") { data { body } paginatorInfo { total } } }').dig('data', 'searchComments')

          expect(page['data'].pluck('body')).not_to include('A brilliant secret.')
          expect(page.dig('paginatorInfo', 'total')).to eq(3)
        end

        it "reads every comment's post in one query when it reindexes" do
          sql = sql_in { Comment.reindex }

          expect(sql.grep(from(:posts)).size).to eq(1)
        end

        it 'answers an empty list for a term nothing matches' do
          expect(bodies('search: "zzzz"')).to eq([])
        end
      end
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
        type PgOrderedPost { id: ID! title: String! }
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
          ordered(search: String @search): [PgOrderedPost!]! @all
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

    it 'ends the order with the primary key, after the rank and the orders that break its ties' do
      order_of = lambda do |query|
        sql_in { run(schema, query) }.grep(from(:posts)).last.sub(%r{\s*/\*.*\*/\z}, '')[/ORDER BY .*\z/]
      end
      key = %("posts"."id")

      expect(order_of.call('{ byTitle(search: "plain") { title } }')).to match(/\AORDER BY .*rank"? DESC, #{Regexp.escape(key)} ASC\z/)
      expect(order_of.call('{ posts(search: "great", orderBy: [{ column: ID, order: DESC }]) { title } }'))
        .to match(/rank"? DESC, #{Regexp.escape(key)} DESC\z/)
    end

    it 'deletes what a search finds, and refuses to delete every post when no search runs' do
      mutations = schema_from(<<~GRAPHQL)
        type PgSearchedPost { id: ID! title: String! }
        type Query { posts: [PgSearchedPost!]! @all }
        type Mutation { deletePosts(search: String @search): [PgSearchedPost!]! @delete }
      GRAPHQL

      ['', '(search: null)'].each do |arguments|
        expect(run(mutations, "mutation { deletePosts#{arguments} { id } }")['errors'].pluck('message'))
          .to eq(['Would modify all models, use an argument to filter.'])
      end
      expect(run(mutations, 'mutation { deletePosts(search: "") { id } }').dig('data', 'deletePosts')).to eq([])
      expect(titles(run(mutations, 'mutation { deletePosts(search: "bad") { title } }'), 'deletePosts')).to eq(['Bad title'])
      expect(PgSearchedPost.count).to eq(3)
    end

    it "sorts a search by rank before the model's default order, which orders the list without one" do
      expect(titles(run(schema, '{ ordered(search: "great") { title } }'), 'ordered')).to eq(['Great great title', 'Great title', 'Plain'])
      expect(titles(run(schema, '{ ordered { title } }'), 'ordered')).to eq(['Plain', 'Great title', 'Great great title', 'Bad title'])
    end

    it "tells pg_search's scopes from Searchkick's `search`, on a model that uses both gems" do
      adapter = Lighthouse::Search::PgSearch.new

      expect([adapter.searchable?(SearchedPost), adapter.named?(SearchedPost, 'search_title'), adapter.searchable?(PgSearchedPost)])
        .to eq([false, true, true])
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
