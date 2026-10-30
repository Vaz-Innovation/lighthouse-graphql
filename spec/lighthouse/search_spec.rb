# frozen_string_literal: true

require 'spec_helper'

# PHP Lighthouse's tests/Integration/Scout/SearchDirectiveTest, with a fake engine
# (FakeSearch::Engine) for Laravel Scout's, and the cases of the Ruby side: a relational
# adapter, the build-time errors, and the adapters' translation to Searchkick and pg_search.
class Builders::SearchSpecCustom
  def self.call(query, value, _context) = query.where('from_custom_builder', value[:id])
end

class Builders::SearchSpecLoadOnly
  def self.call(query, value, _context)
    query.options[:scope_results] = ->(records) { records.where(title: value) }
    query
  end
end

# A resolver of the app's own, which reads the first record the search finds.
class SearchSpecEnhanced
  def self.call(_obj, _args, _ctx, resolve_info)
    found = resolve_info.enhance_builder(SearchPost.all)
    found.is_a?(Lighthouse::Search::Result) ? found.records(first: 1) : found.limit(1)
  end
end

# One that narrows the relation before the search, which an engine outside the database cannot apply.
class SearchSpecNarrowed
  def self.call(_obj, _args, _ctx, resolve_info) = resolve_info.enhance_builder(SearchPost.where(author_id: 1))
end

# One that searches the relation the spec puts in the context, and reads what the engine finds.
class SearchSpecGiven
  def self.call(_obj, _args, ctx, resolve_info)
    found = resolve_info.enhance_builder(ctx[:relation].call)
    found.is_a?(Lighthouse::Search::Result) ? found.records : found.to_a
  end
end

class Builders::SearchSpecOptions
  def self.call(query, value, _context)
    query.options[:fields] = [value]
    query
  end
end

RSpec.describe '@search' do
  def run(schema, query, variables = {})
    schema.execute(query, variables: variables).to_h
  end

  # The SQL statements run inside the block (schema introspection excluded).
  def queries_in(&block)
    sql = []
    callback = ->(*, payload) { sql << payload[:sql] unless payload[:name] == 'SCHEMA' }
    ActiveSupport::Notifications.subscribed(callback, 'sql.active_record', &block)
    sql
  end

  def titles(result, field = 'posts')
    result.dig('data', field).map { |row| row['title'] }
  end

  let(:great) { [SearchPost.create!(title: 'great title'), SearchPost.create!(title: 'Really great title')] }
  let(:engine) { FakeSearch::Engine.new([SearchPost], great) }

  before { SearchPost.delete_all }

  def search_with(engine)
    Lighthouse::Config.search = engine
  end

  describe 'the definition' do
    it "is PHP Lighthouse's, injected when the schema uses it" do
      sdl = Lighthouse::GraphQL::SchemaGenerator.inject_directive_definitions('type Query { posts(search: String @search): [String!]! }')
      directive = GraphQL::Language::Parser.parse(sdl).definitions.find { |definition| definition.respond_to?(:locations) && definition.name == 'search' }

      expect(directive.description).to eq('Perform a full-text search by the given input value.')
      expect(directive.arguments.map { |argument| [argument.name, argument.type.name, argument.description] })
        .to eq([['within', 'String', 'Specify a custom index to use for search.']])
      expect(directive.locations.map(&:name)).to eq(%w[ARGUMENT_DEFINITION INPUT_FIELD_DEFINITION])
    end
  end

  describe 'with an engine outside the database' do
    before { search_with(engine) }

    it 'returns the records the engine found, in its order' do
      schema = build_schema('type SearchPost { id: ID! title: String! } type Query { posts(search: String @search): [SearchPost!]! @all }')

      result = run(schema, '{ posts(search: "great") { id title } }')

      expect(titles(result)).to eq(['great title', 'Really great title'])
      expect(engine.query.term).to eq('great')
      expect(engine.query.model).to eq(SearchPost)
    end

    it 'searches the empty string, but not null or an omitted argument' do
      schema = build_schema('type SearchPost { id: ID! title: String! } type Query { posts(search: String @search): [SearchPost!]! @all }')
      SearchPost.create!(title: 'in the database')

      expect(titles(run(schema, '{ posts(search: "") { title } }'))).to eq(['great title', 'Really great title'])
      expect(engine.requests.size).to eq(1)
      expect(titles(run(schema, '{ posts(search: null) { title } }'))).to eq(['great title', 'Really great title', 'in the database'])
      expect(titles(run(schema, '{ posts { title } }'))).to eq(['great title', 'Really great title', 'in the database'])
      expect(engine.requests.size).to eq(1)
    end

    it 'does not search when @convertEmptyStringsToNull turns the empty string into null' do
      schema = build_schema(<<~GRAPHQL)
        type SearchPost { title: String! }
        type Query { posts(search: String @search): [SearchPost!]! @all @convertEmptyStringsToNull }
      GRAPHQL

      expect(titles(run(schema, '{ posts(search: "") { title } }'))).to eq(['great title', 'Really great title'])
      expect(engine.requests).to be_empty
    end

    it 'narrows an @eq argument as a where on the query' do
      schema = build_schema(<<~GRAPHQL)
        type SearchPost { id: Int! }
        type Query { posts(id: Int @eq, search: String @search): [SearchPost!]! @all }
      GRAPHQL

      result = run(schema, 'query ($id: Int) { posts(id: $id, search: "great") { id } }', { 'id' => 1 })

      expect(result).to eq('data' => { 'posts' => [{ 'id' => great.first.id }, { 'id' => great.last.id }] })
      expect(engine.query.wheres).to eq('id' => 1)
    end

    it "uses @eq's key" do
      schema = build_schema(<<~GRAPHQL)
        type SearchPost { id: Int! }
        type Query { posts(authorId: Int @eq(key: "writer_id"), search: String @search): [SearchPost!]! @all }
      GRAPHQL

      run(schema, '{ posts(authorId: 3, search: "great") { id } }')

      expect(engine.query.wheres).to eq('writer_id' => 3)
    end

    it 'narrows through the fields of an input object, at any depth' do
      schema = build_schema(<<~GRAPHQL)
        type SearchPost { id: Int! }
        input Filter { writer: Int @eq(key: "author_id") }
        type Query { posts(filter: Filter, search: String @search): [SearchPost!]! @all }
      GRAPHQL

      run(schema, '{ posts(filter: { writer: 4 }, search: "great") { id } }')

      expect(engine.query.wheres).to eq('author_id' => 4)
    end

    it 'finds the search in an input object too' do
      schema = build_schema(<<~GRAPHQL)
        type SearchPost { title: String! }
        input Filter { text: String @search }
        type Query { posts(filter: Filter): [SearchPost!]! @all }
      GRAPHQL

      expect(titles(run(schema, '{ posts(filter: { text: "great" }) { title } }'))).to eq(['great title', 'Really great title'])
      expect(engine.query.term).to eq('great')
    end

    it 'gives a @builder on an argument the query, with the argument' do
      schema = build_schema(<<~GRAPHQL)
        type SearchPost { id: Int! }
        input PostsInput { id: Int! }
        type Query {
          posts(
            input: PostsInput! @builder(method: "Builders::SearchSpecCustom@call")
            search: String! @search
          ): [SearchPost!]! @all
        }
      GRAPHQL

      result = run(schema, 'query ($id: Int!) { posts(input: { id: $id }, search: "greatness") { id } }', { 'id' => 1 })

      expect(result.dig('data', 'posts').size).to eq(2)
      expect(engine.query.wheres).to eq('from_custom_builder' => 1)
      expect(engine.query.term).to eq('greatness')
    end

    it "keeps a builder's options for the adapter" do
      schema = build_schema(<<~GRAPHQL)
        type SearchPost { id: Int! }
        type Query { posts(field: String @builder(class: "SearchSpecOptions"), search: String @search): [SearchPost!]! @all }
      GRAPHQL

      run(schema, '{ posts(field: "title", search: "great") { id } }')

      expect(engine.query.options).to eq(fields: ['title'])
    end

    it 'gives @trashed to the query, for the engine to filter on' do
      engine = FakeSearch::Engine.new([SearchSoftPost], [])
      search_with(engine)
      schema = build_schema(<<~GRAPHQL)
        type SearchSoftPost { id: Int! }
        type Query { posts(id: Int @eq, search: String @search): [SearchSoftPost!]! @all @softDeletes }
      GRAPHQL

      expect(run(schema, '{ posts(search: "foo", trashed: ONLY) { id } }')).to eq('data' => { 'posts' => [] })
      expect(engine.query.trashed).to eq(:only)
      run(schema, '{ posts(search: "foo", trashed: WITH) { id } }')
      expect(engine.query.trashed).to eq(:with)
      run(schema, '{ posts(search: "foo") { id } }')
      expect(engine.query.trashed).to be_nil
    end

    it 'searches within a custom index' do
      schema = build_schema(<<~GRAPHQL)
        type SearchPost { id: ID! }
        type Query { posts(search: String @search(within: "my.index")): [SearchPost!]! @all }
      GRAPHQL

      expect(run(schema, '{ posts(search: "great") { id } }').dig('data', 'posts').size).to eq(2)
      expect(engine.query.index).to eq('my.index')
    end

    it 'reads @all through first and offset' do
      schema = build_schema(<<~GRAPHQL)
        type SearchPost { title: String! }
        type Query { posts(first: Int, offset: Int, search: String @search): [SearchPost!]! @all }
      GRAPHQL

      expect(titles(run(schema, '{ posts(search: "great", first: 1, offset: 1) { title } }'))).to eq(['Really great title'])
      expect(engine.requests.last).to include(offset: 1, limit: 1)
      expect(titles(run(schema, '{ posts(search: "great") { title } }')).size).to eq(2)
      expect(engine.requests.last).to include(offset: 0, limit: Lighthouse::Search::Result::MAX_WINDOW)
    end

    it 'reads @all without first 10,000 records at most, whatever the result window' do
      allow(engine).to receive(:result_window).and_return(1_000_000_000)
      schema = build_schema('type SearchPost { title: String! } type Query { posts(first: Int, search: String @search): [SearchPost!]! @all }')

      run(schema, '{ posts(search: "great") { title } }')
      expect(engine.requests.last).to include(offset: 0, limit: 10_000)
      run(schema, '{ posts(search: "great", first: 50000) { title } }')
      expect(engine.requests.last).to include(offset: 0, limit: 50_000)
    end

    it "reads @all no further than the engine's result window, whatever the offset" do
      schema = build_schema(<<~GRAPHQL)
        type SearchPost { title: String! }
        type Query { posts(first: Int, offset: Int, search: String @search): [SearchPost!]! @all }
      GRAPHQL

      expect(titles(run(schema, '{ posts(search: "great", offset: 1) { title } }'))).to eq(['Really great title'])
      expect(engine.requests.last).to include(offset: 1, limit: Lighthouse::Search::Result::MAX_WINDOW - 1)
      run(schema, '{ posts(search: "great", first: 10, offset: 9995) { title } }')
      expect(engine.requests.last).to include(offset: 9995, limit: 5)
    end

    it 'refuses a page past the result window, with an error the client reads' do
      schema = build_schema('type SearchPost { title: String! } type Query { posts(search: String @search): [SearchPost!]! @paginate }')

      result = run(schema, '{ posts(first: 10, page: 1001, search: "great") { data { title } } }')

      expect(result['errors'].pluck('message')).to eq(
        ['The search reads no further than its first 10000 matches (the index.max_result_window of SearchPost), so offset 10000 is past them. ' \
         'Narrow the search instead.']
      )
      expect(engine.requests).to be_empty
    end

    describe 'with @paginate' do
      let(:schema) do
        build_schema('type SearchPost { id: ID! title: String! } type Query { posts(search: String @search): [SearchPost!]! @paginate }')
      end

      it 'pages the engine, with the total from the same request' do
        result = run(schema,
                     '{ posts(first: 1, page: 2, search: "great") { data { title } paginatorInfo { total lastPage currentPage hasMorePages } } }')

        expect(result.dig('data', 'posts')).to eq(
          'data' => [{ 'title' => 'Really great title' }],
          'paginatorInfo' => { 'total' => 2, 'lastPage' => 2, 'currentPage' => 2, 'hasMorePages' => false }
        )
        expect(engine.requests.size).to eq(1)
        expect(engine.requests.first).to include(offset: 1, limit: 1)
      end

      it 'asks no more than the data when the client selects no total' do
        run(schema, '{ posts(first: 10, search: "great") { data { id } } }')

        expect(engine.requests.size).to eq(1)
      end

      it 'counts with first: 0, which Scout cannot' do
        result = run(schema, '{ posts(first: 0, search: "great") { data { id } paginatorInfo { total } } }')

        expect(result.dig('data', 'posts')).to eq('data' => [], 'paginatorInfo' => { 'total' => 2 })
        expect(engine.requests.pluck(:limit)).to eq([0])
      end

      it 'pages SIMPLE with one extra record, and CONNECTION by position' do
        sdl = 'type SearchPost { title: String! } type Query { posts(search: String @search): [SearchPost!]! @paginate(type: %s) }'
        simple = build_schema(format(sdl, 'SIMPLE'))
        connection = build_schema(format(sdl, 'CONNECTION'))

        expect(run(simple, '{ posts(first: 1, search: "g") { data { title } paginatorInfo { hasMorePages } } }').dig('data', 'posts'))
          .to eq('data' => [{ 'title' => 'great title' }], 'paginatorInfo' => { 'hasMorePages' => true })
        expect(engine.requests.last).to include(offset: 0, limit: 2)

        page = run(connection, '{ posts(first: 1, search: "g") { edges { cursor node { title } } pageInfo { hasNextPage endCursor total } } }')
        expect(page.dig('data', 'posts', 'edges').map { |edge| edge.dig('node', 'title') }).to eq(['great title'])
        expect(page.dig('data', 'posts', 'pageInfo')).to include('hasNextPage' => true, 'total' => 2)

        after = page.dig('data', 'posts', 'pageInfo', 'endCursor')
        second = run(connection, "{ posts(first: 1, after: \"#{after}\", search: \"g\") { edges { node { title } } pageInfo { hasNextPage } } }")
        expect(second.dig('data',
                          'posts')).to eq('edges' => [{ 'node' => { 'title' => 'Really great title' } }], 'pageInfo' => { 'hasNextPage' => false })
        expect(engine.requests.last).to include(offset: 1, limit: 1)
      end

      it 'falls back to the database when the client does not search' do
        SearchPost.create!(title: 'other')

        result = run(schema, '{ posts(first: 10) { data { title } paginatorInfo { total } } }')

        expect(result.dig('data', 'posts', 'paginatorInfo', 'total')).to eq(3)
        expect(engine.requests).to be_empty
      end

      it 'requires first, like any page' do
        result = run(schema, '{ posts(search: "great") { data { id } } }')

        expect(result['errors'].first['message']).to include('first')
      end
    end

    describe 'loading what Searchkick finds' do
      before do
        stub_const('Searchkick', Module.new)
        search_with(Lighthouse::Search::Searchkick.new)
        SearchPost.delete_all
      end

      {
        'paranoia' => [SearchkickParanoidPost, :deleted_at],
        'discard' => [SearchkickDiscardPost, :discarded_at],
        'a deleted_at column under a default scope' => [SearchkickHiddenPost, :deleted_at]
      }.each do |strategy, (model, column)|
        it "loads the trashed records @trashed asks for, past the default scope that hides them, with #{strategy}" do
          kept = model.create!(title: 'kept')
          trashed = model.create!('title' => 'trashed', column => Time.current)
          schema = build_schema(<<~GRAPHQL)
            type #{model.name} { title: String! }
            type Query { posts(search: String @search): [#{model.name}!]! @paginate @softDeletes }
          GRAPHQL
          titles_of = lambda do |trashed_value|
            page = run(schema, "{ posts(first: 10, search: \"x\", trashed: #{trashed_value}) { data { title } paginatorInfo { total } } }")
            [page.dig('data', 'posts', 'data').pluck('title'), page.dig('data', 'posts', 'paginatorInfo', 'total')]
          end

          expect(titles_of.call('ONLY')).to eq([['trashed'], 1])
          expect(titles_of.call('WITH')).to eq([%w[kept trashed], 2])
          expect(titles_of.call('WITHOUT')).to eq([['kept'], 1])
          expect([kept, trashed].map { |record| model.unscoped.exists?(record.id) }).to eq([true, true])
        end
      end

      it "filters on paranoia's sentinel, which a kept record holds in place of null" do
        model = SearchkickSentinelPost
        model.create!(title: 'kept')
        model.create!(title: 'trashed').destroy
        schema = build_schema(<<~GRAPHQL)
          type SearchkickSentinelPost { title: String! }
          type Query { posts(search: String @search): [SearchkickSentinelPost!]! @paginate @softDeletes }
        GRAPHQL
        titles_of = lambda do |trashed|
          run(schema, "{ posts(first: 10, search: \"x\", trashed: #{trashed}) { data { title } } }").dig('data', 'posts', 'data').pluck('title')
        end

        expect(model.unscoped.pluck(:title, :deleted_at).map { |title, at| [title, at.year] })
          .to contain_exactly(['kept', 0], ['trashed', Time.current.year])
        expect([titles_of.call('ONLY'), titles_of.call('WITHOUT')]).to eq([['trashed'], ['kept']])
        expect(model.searches.last[:where]).to eq(deleted_at: DateTime.new(0))
      end

      it 'filters on the column Config.soft_deletes names' do
        Lighthouse::Config.soft_deletes = Lighthouse::Support::SoftDeletes::Column.new(:discarded_at)
        SearchkickHiddenPost.create!(title: 'kept')
        SearchkickHiddenPost.create!(title: 'archived', discarded_at: Time.current)
        schema = build_schema(<<~GRAPHQL)
          type SearchkickHiddenPost { title: String! }
          type Query { posts(search: String @search): [SearchkickHiddenPost!]! @all @softDeletes }
        GRAPHQL

        expect(titles(run(schema, '{ posts(search: "x", trashed: ONLY) { title } }'))).to eq(['archived'])
        expect(SearchkickHiddenPost.searches.last[:where]).to eq(discarded_at: { not: nil })
      end

      it "loads the hits through the model's search_results scope, which a stale index cannot get past" do
        SearchkickGuardedPost.create!(title: 'fresh')
        SearchkickGuardedPost.create!(title: 'stale')
        schema = build_schema(<<~GRAPHQL)
          type SearchkickGuardedPost { title: String! }
          type Query { posts(search: String @search): [SearchkickGuardedPost!]! @all }
        GRAPHQL

        expect(titles(run(schema, '{ posts(search: "x") { title } }'))).to eq(['fresh'])
      end

      it "keeps the app's own scope_results, after the model's" do
        SearchkickGuardedPost.create!(title: 'fresh')
        SearchkickGuardedPost.create!(title: 'other')
        schema = build_schema(<<~GRAPHQL)
          type SearchkickGuardedPost { title: String! }
          type Query { posts(search: String @search, only: String @builder(class: "SearchSpecLoadOnly")): [SearchkickGuardedPost!]! @all }
        GRAPHQL

        expect(titles(run(schema, '{ posts(search: "x", only: "other") { title } }'))).to eq(['other'])
      end
    end

    describe 'with @canQuery' do
      let(:schema) do
        build_schema(<<~GRAPHQL)
          type SearchPost { id: ID! title: String! }
          type Query { posts(search: String @search): [SearchPost!]! @paginate @canQuery(ability: "view") }
        GRAPHQL
      end

      # A post titled "secret" may not be viewed.
      before { Lighthouse::Config.authorizer = ->(_user, record, _ability) { record.title != 'secret' } }

      it 'checks each record the search finds, then pages them, as PHP Lighthouse checks the hits of the Scout builder' do
        result = run(schema, '{ posts(first: 1, search: "great") { data { title } } }')

        expect(result).to eq('data' => { 'posts' => { 'data' => [{ 'title' => 'great title' }] } })
        expect(engine.requests.map { |request| request.slice(:offset, :limit) })
          .to eq([{ offset: 0, limit: Lighthouse::Search::Result::MAX_WINDOW }, { offset: 0, limit: 1 }])
      end

      it 'denies the field when the search finds a record the user may not see, on any page' do
        search_with(FakeSearch::Engine.new([SearchPost], great + [SearchPost.new(title: 'secret')]))

        result = run(schema, '{ posts(first: 1, search: "great") { data { title } } }')

        expect(result['errors'].pluck('message')).to eq(['This action is unauthorized.'])
      end

      it 'reads no more than 10,000 records to check, whatever the result window' do
        allow(engine).to receive(:result_window).and_return(1_000_000_000)
        all = build_schema(<<~GRAPHQL)
          type SearchPost { title: String! }
          type Query { posts(search: String @search): [SearchPost!]! @all @canQuery(ability: "view") }
        GRAPHQL

        run(all, '{ posts(search: "great") { title } }')

        expect(engine.requests.pluck(:limit)).to eq([10_000, 10_000])
      end

      it 'refuses a search with more matches than it can check that a page could reach, not those past the result window' do
        many = ->(original, *args, **options) { [original.call(*args, **options).first, 10_001] }
        allow(engine).to receive(:page).and_wrap_original(&many)
        query = '{ posts(first: 1, search: "great") { data { title } } }'

        expect(run(schema, query)['errors']).to be_nil
        allow(engine).to receive(:result_window).and_return(20_000)
        expect(run(schema, query)['errors'].pluck('message'))
          .to eq(['@canQuery checks every record the search finds, at most 10000, and this one finds 10001. Narrow the search.'])
      end

      it 'checks the records of the database when the client does not search' do
        SearchPost.create!(title: 'secret')

        expect(run(schema, '{ posts(first: 1) { data { title } } }')['errors'].pluck('message')).to eq(['This action is unauthorized.'])
        expect(engine.requests).to be_empty
      end
    end

    describe 'through resolve_info.enhance_builder' do
      let(:schema) do
        build_schema(<<~GRAPHQL)
          type SearchPost { title: String! }
          type Query {
            found(search: String @search): [SearchPost!]! @field(resolver: "SearchSpecEnhanced")
            narrowed(search: String @search): [SearchPost!]! @field(resolver: "SearchSpecNarrowed")
          }
        GRAPHQL
      end

      it "answers the search, as PHP Lighthouse's enhanceBuilder answers Scout's builder" do
        expect(titles(run(schema, '{ found(search: "great") { title } }'), 'found')).to eq(['great title'])
        expect(engine.requests.last).to include(offset: 0, limit: 1)
      end

      it "searches a model whose default scope reads the clock, and compiles no SQL to tell the model's relation" do
        timed = FakeSearch::Engine.new([SearchTimedPost], great)
        search_with(timed)
        schema = build_schema('type SearchTimedPost { title: String! } type Query { posts(search: String @search): [SearchTimedPost!]! @all }')
        expect_any_instance_of(ActiveRecord::Relation).not_to receive(:to_sql) # rubocop:disable RSpec/AnyInstance

        expect(titles(run(schema, '{ posts(search: "great") { title } }'))).to eq(['great title', 'Really great title'])
      end

      it 'refuses a relation narrowed beforehand, whose conditions the engine would drop' do
        expect { run(schema, '{ narrowed(search: "great") { title } }') }
          .to raise_error(Lighthouse::DefinitionError, /searches the whole index of SearchPost: it cannot apply the conditions of the relation/)
      end

      describe 'on a model whose default scope hides records (paranoia)' do
        let(:model) { SearchkickParanoidPost }
        let(:given) do
          search_with(FakeSearch::Engine.new([model], great))
          given_schema(model.name)
        end

        # A field resolved by SearchSpecGiven, which searches the relation the context holds.
        def given_schema(model)
          build_schema(<<~GRAPHQL)
            type #{model} { title: String! }
            type Query { found(search: String @search): [#{model}!]! @field(resolver: "SearchSpecGiven") }
          GRAPHQL
        end

        def search(relation) = given.execute('{ found(search: "great") { title } }', context: { relation: relation }).to_h

        it 'refuses any relation that selects other records than the model, even with as many conditions as its own' do
          {
            'with_deleted, then a condition' => -> { model.with_deleted.where(author_id: 1) },
            'unscoped, then a condition' => -> { model.unscoped.where(author_id: 1) },
            'one condition swapped for another' => -> { model.unscope(where: :deleted_at).where(author_id: 1) },
            'rewhere' => -> { model.rewhere(deleted_at: Time.current) },
            'merge' => -> { model.merge(model.unscoped.where(author_id: 1)) },
            'joins with a condition' => -> { model.joins('INNER JOIN search_posts authors ON authors.id = search_posts.author_id') },
            'none' => -> { model.none },
            'from' => -> { model.from('search_posts AS search_posts') }
          }.each do |form, relation|
            expect { search(relation) }.to raise_error(Lighthouse::DefinitionError, /cannot apply the conditions/), form
          end
        end

        it 'refuses, when in doubt, a model whose default scope reads the clock: its own relation cannot be told from another' do
          search_with(FakeSearch::Engine.new([SearchTimedPost], great))
          timed = given_schema('SearchTimedPost')

          expect { timed.execute('{ found(search: "great") { title } }', context: { relation: -> { SearchTimedPost.all } }) }
            .to raise_error(Lighthouse::DefinitionError, /cannot apply the conditions/)
        end

        it "searches the model's own relation, or the relation in another order" do
          [-> { model.all }, -> { model.order(:title) }].each do |relation|
            expect(search(relation).dig('data', 'found').pluck('title')).to eq(['great title', 'Really great title'])
          end
        end
      end
    end

    describe 'when the client asks for what an engine cannot do' do
      it 'sends two searches' do
        schema = build_schema(<<~GRAPHQL)
          type SearchPost { id: ID! }
          type Query { posts(one: String @search, two: String @search): [SearchPost!]! @all }
        GRAPHQL

        result = run(schema, '{ posts(one: "great", two: "nope") { id } }')

        expect(result['errors'].first['message']).to eq('Found more than 1 argument with @search.')
        expect(engine.requests).to be_empty
      end

      it 'searches once when only one of two searches is sent' do
        schema = build_schema(<<~GRAPHQL)
          type SearchPost { id: ID! }
          type Query { posts(one: String @search, two: String @search): [SearchPost!]! @all }
        GRAPHQL

        expect(run(schema, '{ posts(one: "great", two: null) { id } }')['errors']).to be_nil
        expect(engine.query.term).to eq('great')
      end

      it 'sends an argument whose directive does not support a search' do
        schema = build_schema(<<~GRAPHQL)
          type SearchPost { id: ID! }
          type Query { posts(search: String @search, nope: String @neq): [SearchPost!]! @all }
        GRAPHQL

        result = run(schema, '{ posts(search: "great", nope: "nope") { id } }')

        expect(result['errors'].first['message']).to eq('Found arg builder arguments that do not work with @search: @neq on nope.')
        expect(run(schema, '{ posts(search: "great") { id } }')['errors']).to be_nil
      end

      it 'sends an @orderBy or @whereConditions, which are database ones' do
        schema = build_schema(<<~GRAPHQL)
          type SearchPost { id: ID! title: String }
          type Query {
            posts(search: String @search, orderBy: _ @orderBy(columns: ["title"]), where: _ @whereConditions(columns: ["title"])): [SearchPost!]! @all
          }
        GRAPHQL

        ordered = run(schema, '{ posts(search: "great", orderBy: [{ column: TITLE, order: ASC }]) { id } }')
        filtered = run(schema, '{ posts(search: "great", where: { column: TITLE, value: "x" }) { id } }')

        expect(ordered['errors'].first['message']).to include('@orderBy')
        expect(filtered['errors'].first['message']).to include('@whereConditions')
      end
    end
  end

  describe 'at build time' do
    it 'wants a string for within' do
      expect do
        build_schema('type SearchPost { id: ID! } type Query { posts(search: String @search(within: 123)): [SearchPost!]! @all }')
      end.to raise_error(Lighthouse::DefinitionError, /@search on Query.posts\(search\): expected the value of the `within` argument .* got: 123/)
    end

    it 'wants a searchable model' do
      search_with(FakeSearch::Engine.new([SearchPost]))

      expect do
        build_schema('type Widget { id: ID! } type Query { widgets(search: String @search): [Widget!]! @all }')
      end.to raise_error(Lighthouse::DefinitionError, /Widget is not searchable/)
    end

    it 'finds no engine without Searchkick or pg_search in the app' do
      expect do
        build_schema('type SearchPost { id: ID! } type Query { posts(search: String @search): [SearchPost!]! @all }')
      end.to raise_error(Lighthouse::DefinitionError, /SearchPost is not searchable/)
    end

    it 'reads the model from the directive' do
      search_with(FakeSearch::Engine.new([SearchPost]))

      expect do
        build_schema('type Hit { id: ID! } type Query { hits(search: String @search): [Hit!]! @all(model: "SearchPost") }')
      end.not_to raise_error
    end

    it "reads the model of the directive that resolves the field, not another directive's, as the resolver does" do
      search_with(FakeSearch::Engine.new([SearchPost]))

      expect do
        build_schema(<<~GRAPHQL)
          type Hit { id: ID! }
          type Query { hits(search: String @search): [Hit!]! @canModel(ability: "view", model: "Widget") @paginate(model: "SearchPost") }
        GRAPHQL
      end.not_to raise_error
    end

    it 'leaves a field whose model it cannot tell to the resolver' do
      expect do
        build_schema('type Hit { id: ID! } type Query { hits(search: String @search): [Hit!]! }')
      end.not_to raise_error
    end

    context 'with an engine outside the database' do
      before { search_with(FakeSearch::Engine.new([SearchPost])) }

      def build_posts(field)
        build_schema("type SearchPost { id: ID! posts: [SearchPost!]! } type Query { #{field} }")
      end

      it 'refuses what drops silently in PHP Lighthouse' do
        {
          'posts(search: String @search): [SearchPost!]! @all(scopes: ["recent"])' => '`scopes:`',
          'posts(search: String @search): [SearchPost!]! @paginate(scopes: ["recent"])' => '`scopes:`',
          'posts(search: String @search): [SearchPost!]! @all @builder(class: "Published")' => '@builder',
          'posts(search: String @search): [SearchPost!]! @all @whereAuth(relation: "user")' => '@whereAuth',
          'posts(search: String @search): [SearchPost!]! @all @orderBy(column: "title")' => '@orderBy'
        }.each do |field, dropped|
          expect { build_posts(field) }.to raise_error(Lighthouse::DefinitionError, /Engine cannot apply .*#{Regexp.escape(dropped)}/)
        end
      end

      it 'refuses an @canQuery whose scopes the engine cannot apply, or whose model it cannot search' do
        expect { build_posts('posts(search: String @search): [SearchPost!]! @all @canQuery(ability: "view", scopes: ["recent"])') }
          .to raise_error(Lighthouse::DefinitionError, /Engine cannot apply the `scopes:` of @canQuery/)
        expect { build_posts('posts(search: String @search): [SearchPost!]! @all @canQuery(ability: "view", model: "Widget")') }
          .to raise_error(Lighthouse::DefinitionError, /Widget is not searchable/)
      end

      it "refuses a field that reads an association of a searchable model, which the field's type does not name" do
        expect do
          build_schema(<<~GRAPHQL)
            type SearchPost { id: ID! relatedCount(search: String @search): Int! @count(relation: "related") }
            type Query { posts: [SearchPost!]! @all }
          GRAPHQL
        end.to raise_error(Lighthouse::DefinitionError, /SearchPost.relatedCount\(search\): .*needs @all, @paginate/)
      end

      it 'refuses a default value a directive the engine cannot apply would apply to every search, as an argument or an input field' do
        {
          'posts(search: String @search, orderBy: [OrderByClause!] = [{ column: "title", order: ASC }] @orderBy): [SearchPost!]! @all' =>
            '@orderBy on orderBy',
          'posts(search: String @search, minId: Int = 1 @where(operator: ">", key: "id")): [SearchPost!]! @all' => '@where on minId',
          'posts(search: String @search, filter: PostsFilter): [SearchPost!]! @all' => '@neq on filter.title'
        }.each do |field, refused|
          expect { build_schema("type SearchPost { id: ID! } input PostsFilter { title: String = \"x\" @neq } type Query { #{field} }") }
            .to raise_error(Lighthouse::DefinitionError, /Engine cannot apply #{Regexp.escape(refused)}, whose default value/)
        end
      end

      it 'accepts a default value for a directive the engine applies, and leaves the defaults alone with a relational adapter' do
        sdl = 'type SearchPost { id: ID! } ' \
              'type Query { posts(search: String @search, authorId: Int = 1 @eq(key: "author_id"), minId: Int = 1 %s): [SearchPost!]! @all }'

        expect { build_schema(format(sdl, '')) }.not_to raise_error
        search_with(FakeSearch::Relational.new([SearchPost]))
        expect { build_schema(format(sdl, '@where(operator: ">", key: "id")')) }.not_to raise_error
      end

      it 'accepts @all and @paginate on a root field' do
        expect do
          build_posts('a(search: String @search): [SearchPost!]! @all b(search: String @search): [SearchPost!]! @paginate')
        end.not_to raise_error
      end

      it 'refuses any other directive: the engine answers with records, not a relation' do
        %w[@first @count @delete].each do |directive|
          expect { build_posts("posts(search: String @search): SearchPost #{directive}(model: \"SearchPost\")") }
            .to raise_error(Lighthouse::DefinitionError, /needs @all, @paginate on a root field or with its own `model:`, or a resolver of your own/)
        end
        expect do
          build_posts('posts(search: String @search): SearchPost @find')
        end.to raise_error(Lighthouse::DefinitionError, /needs @all, @paginate/)
      end

      it 'accepts a field your own class resolves, which reads the search through resolve_info.enhance_builder' do
        expect do
          build_posts('a(search: String @search): [SearchPost!]! @field(resolver: "SearchSpecEnhanced") b(search: String @search): [SearchPost!]!')
        end.not_to raise_error
      end

      it 'refuses a nested field, which pages a relation' do
        expect do
          build_schema(<<~GRAPHQL)
            type SearchPost { id: ID! related(search: String @search): [SearchPost!]! @paginate }
            type Query { posts: [SearchPost!]! @all }
          GRAPHQL
        end.to raise_error(Lighthouse::DefinitionError, /SearchPost.related\(search\): .*needs @all, @paginate on a root field/)
      end

      it "refuses a nested @paginate when the model: is another directive's: it still pages the parent's association" do
        expect do
          build_schema(<<~GRAPHQL)
            type SearchPost { id: ID! related(search: String @search): [SearchPost!]! @paginate @canModel(ability: "view", model: "SearchPost") }
            type Query { posts: [SearchPost!]! @all }
          GRAPHQL
        end.to raise_error(Lighthouse::DefinitionError, /needs @all, @paginate on a root field or with its own `model:`, or a resolver of your own/)
      end

      it 'accepts a nested @paginate that names its model' do
        expect do
          build_schema(<<~GRAPHQL)
            type SearchPost { id: ID! related(search: String @search): [SearchPost!]! @paginate(model: "SearchPost") }
            type Query { posts: [SearchPost!]! @all }
          GRAPHQL
        end.not_to raise_error
      end
    end
  end

  describe 'with a relational adapter' do
    let(:relational) { FakeSearch::Relational.new([SearchPost]) }
    let(:schema) do
      build_schema(<<~GRAPHQL)
        type SearchPost { id: ID! title: String! author: SearchPost }
        type Query {
          posts(
            search: String @search
            authorId: Int @eq(key: "author_id")
            where: _ @whereConditions(columns: ["title"])
            orderBy: _ @orderBy(columns: ["id"])
          ): [SearchPost!]! @all(scopes: ["with_author"]) @builder(class: "SearchSpecOnlyBodied")
          paged(search: String @search, authorId: Int @eq(key: "author_id")): [SearchPost!]! @paginate
          one(search: String @search): SearchPost @first
          many(search: String @search): Int! @count(model: "SearchPost")
        }
      GRAPHQL
    end

    before do
      search_with(relational)
      SearchPost.delete_all
      SearchPost.create!(title: 'great one', body: 'x', author_id: 1)
      SearchPost.create!(title: 'great two', body: nil, author_id: 1)
      SearchPost.create!(title: 'great three', body: 'x', author_id: 2)
      SearchPost.create!(title: 'bad', body: 'x', author_id: 1)
    end

    it 'searches the relation, and every other directive applies on top of it' do
      result = run(schema, '{ posts(search: "great", authorId: 1) { title } }')

      expect(titles(result)).to eq(['great one'])
    end

    it 'keeps the scopes, the @builder, @whereConditions and the client order' do
      result = run(schema, <<~GRAPHQL)
        { posts(search: "great", where: { column: TITLE, operator: NEQ, value: "great one" }, orderBy: [{ column: ID, order: DESC }]) { title } }
      GRAPHQL

      expect(titles(result)).to eq(['great three'])
      all = run(schema, '{ posts(search: "great", orderBy: [{ column: ID, order: DESC }]) { title } }')
      expect(titles(all)).to eq(['great three', 'great one'])
    end

    it 'does not search without the argument' do
      expect(titles(run(schema, '{ posts { title } }')).size).to eq(3)
      expect(relational.queries).to be_empty
    end

    describe 'on a mass mutation' do
      let(:relational) { FakeSearch::Relational.new([SearchPost, SearchSoftPost]) }
      let(:mutations) do
        build_schema(<<~GRAPHQL)
          type SearchPost { id: ID! title: String! }
          type SearchSoftPost { id: ID! title: String! }
          type Query { posts: [SearchPost!]! @all }
          type Mutation {
            deletePosts(search: String @search): [SearchPost!]! @delete
            forceDeletePosts(search: String @search): [SearchSoftPost!]! @forceDelete
            restorePosts(search: String @search): [SearchSoftPost!]! @restore
          }
        GRAPHQL
      end

      it 'refuses to modify every row when the client sends no search, or null: a search that does not run filters nothing' do
        SearchSoftPost.where(title: 'bad').update_all(deleted_at: Time.current) # rubocop:disable Rails/SkipsModelValidations

        %w[deletePosts forceDeletePosts restorePosts].product(['', '(search: null)']).each do |field, arguments|
          result = run(mutations, "mutation { #{field}#{arguments} { id } }")

          expect(result['errors'].pluck('message')).to eq(['Would modify all models, use an argument to filter.'])
        end
        expect([SearchPost.count, SearchSoftPost.where.not(deleted_at: nil).count]).to eq([4, 1])
      end

      it 'modifies what the search finds' do
        run(mutations, 'mutation { deletePosts(search: "great") { id } }')

        expect(SearchPost.pluck(:title)).to eq(['bad'])
      end
    end

    it "walks the field's argument directives once a request, and its @search arguments once a schema" do
      schema
      walks = 0
      count = ->(original, *args) { (walks += 1) && original.call(*args) }
      allow(Lighthouse::Support::ArgumentWalk).to receive(:definitions).and_call_original
      allow_any_instance_of(Lighthouse::GraphQL::DirectiveResolvers::BaseDirectiveResolver) # rubocop:disable RSpec/AnyInstance
        .to receive(:arg_builders).and_wrap_original(&count)

      2.times { run(schema, '{ posts(search: "great", authorId: 1) { title } }') }

      expect(walks).to eq(2)
      expect(Lighthouse::Support::ArgumentWalk).not_to have_received(:definitions)
    end

    it 'walks the arguments of a searched field once for its searches when the schema is built, as for its @canModel' do
      allow(Lighthouse::Support::ArgumentWalk).to receive(:definitions).and_call_original

      built = build_schema('type SearchPost { id: ID! } type Query { posts(search: String @search, id: ID @eq): [SearchPost!]! @all }')

      arguments = built.query.fields['posts'].arguments
      expect(Lighthouse::Support::ArgumentWalk).to have_received(:definitions).with(arguments).twice
    end

    it 'ends the order with the primary key, after the orders that decide ties, once' do
      last_order = lambda do |query|
        queries_in { run(schema, query) }.grep(/FROM "search_posts"/).last[/ORDER BY .*\z/]
      end

      expect(last_order.call('{ posts(search: "great") { title } }')).to eq('ORDER BY "search_posts"."id" ASC')
      expect(last_order.call('{ posts(search: "great", orderBy: [{ column: ID, order: DESC }]) { title } }'))
        .to eq('ORDER BY "search_posts"."id" DESC')
      expect(last_order.call('{ posts { title } }')).to be_nil
    end

    it 'pages, counts, takes the first and counts the relation' do
      paged = run(schema, '{ paged(first: 2, search: "great", authorId: 1) { data { title } paginatorInfo { total } } }')
      expect(paged.dig('data',
                       'paged')).to eq('data' => [{ 'title' => 'great one' }, { 'title' => 'great two' }], 'paginatorInfo' => { 'total' => 2 })

      expect(run(schema, '{ one(search: "three") { title } }').dig('data', 'one', 'title')).to eq('great three')
      expect(run(schema, '{ many(search: "great") }').dig('data', 'many')).to eq(3)
    end

    it 'gives the adapter the term and the index' do
      indexed = build_schema('type SearchPost { id: ID! } type Query { posts(search: String @search(within: "by_title")): [SearchPost!]! @all }')

      run(indexed, '{ posts(search: "great") { id } }')

      expect(relational.queries.last).to have_attributes(term: 'great', index: 'by_title', model: SearchPost)
    end

    it 'searches a nested field too, a paginated one batched with the other parents' do
      nested = build_schema(<<~GRAPHQL, dataloader: true)
        type SearchPost {
          id: ID!
          title: String!
          many(search: String @search): [SearchPost!]! @hasMany(relation: "related")
          paged(search: String @search): [SearchPost!]! @paginate
        }
        type Query { roots: [SearchPost!]! @all(scopes: ["roots"]) }
      GRAPHQL
      SearchPost.delete_all
      first = SearchPost.create!(title: 'first', author_id: nil)
      second = SearchPost.create!(title: 'second', author_id: nil)
      [[first, 'great a'], [first, 'bad a'], [second, 'great b'], [second, 'great c']].each do |parent, title|
        SearchPost.create!(title: title, author_id: parent.id)
      end

      query = <<~GRAPHQL
        { roots { title many(search: "great") { title } paged(first: 5, search: "great") { data { title } paginatorInfo { total } } } }
      GRAPHQL
      result = nil
      queries = queries_in { result = run(nested, query) }

      expect(result.dig('data', 'roots')).to eq(
        [
          { 'title' => 'first', 'many' => [{ 'title' => 'great a' }],
            'paged' => { 'data' => [{ 'title' => 'great a' }], 'paginatorInfo' => { 'total' => 1 } } },
          { 'title' => 'second', 'many' => [{ 'title' => 'great b' }, { 'title' => 'great c' }],
            'paged' => { 'data' => [{ 'title' => 'great b' }, { 'title' => 'great c' }], 'paginatorInfo' => { 'total' => 2 } } }
        ]
      )
      expect(queries.grep(/ROW_NUMBER/).size).to eq(1)
      expect(queries.grep(/GROUP BY/).size).to eq(1)
    end
  end

  describe Lighthouse::Search::Query do
    it 'holds what the directives write' do
      query = described_class.new(SearchPost, 'great', 'idx')

      expect(query.where(:id, 1)).to equal(query)
      expect(query).to have_attributes(model: SearchPost, term: 'great', index: 'idx', wheres: { 'id' => 1 }, options: {}, trashed: nil)
    end
  end

  describe Lighthouse::Search::Result do
    let(:engine) { FakeSearch::Engine.new([SearchPost], %w[a b c].map { |title| SearchPost.new(title: title) }) }
    let(:result) { described_class.new(engine, Lighthouse::Search::Query.new(SearchPost, 'x')) }

    it 'asks the engine for a window and keeps the total it answers with' do
      expect(result.window(1, 1).map(&:title)).to eq(['b'])
      expect(result.count).to eq(3)
      expect(engine.requests.size).to eq(1)
    end

    it 'asks for no records to count' do
      expect(result.count).to eq(3)
      expect(engine.requests).to contain_exactly(include(offset: 0, limit: 0))
    end

    it 'asks for nothing for a window of none' do
      expect(result.window(0, 0)).to eq([])
      expect(engine.requests).to be_empty
    end

    it 'reads past any window when the adapter does not know it, and leaves the refusal to the engine' do
      allow(engine).to receive(:result_window).and_return(nil)

      result.window(20_000, 10)
      expect(engine.requests.last).to include(offset: 20_000, limit: 10)
    end

    it "reads within the window the adapter answers for the model's index" do
      allow(engine).to receive(:result_window).and_return(3)

      expect(result.records(offset: 1).map(&:title)).to eq(%w[b c])
      expect(engine.requests.last).to include(offset: 1, limit: 2)
      expect { result.window(3, 1) }.to raise_error(GraphQL::ExecutionError, /no further than its first 3 matches/)
    end
  end

  describe Lighthouse::Search do
    it 'detects nothing without the gems, and Config.search replaces it' do
      expect(described_class.adapter_for(SearchPost)).to be_nil
      engine = FakeSearch::Engine.new([SearchPost])
      search_with(engine)
      expect(described_class.adapter_for(SearchPost)).to equal(engine)
      expect(described_class.adapter_for(Widget)).to be_nil
    end
  end
end
