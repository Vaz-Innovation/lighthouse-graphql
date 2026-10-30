# frozen_string_literal: true

require 'spec_helper'

# PHP Lighthouse's tests/Integration/Scout/SearchDirectiveTest, with a fake engine
# (FakeSearch::Engine) for Laravel Scout's, and the cases of the Ruby side: a relational
# adapter, the build-time errors, and the adapters' translation to Searchkick and pg_search.
class Builders::SearchSpecCustom
  def self.call(query, value, _context) = query.where('from_custom_builder', value[:id])
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

      it 'accepts @all and @paginate on a root field' do
        expect do
          build_posts('a(search: String @search): [SearchPost!]! @all b(search: String @search): [SearchPost!]! @paginate')
        end.not_to raise_error
      end

      it 'refuses any other directive: the engine answers with records, not a relation' do
        %w[@first @count].each do |directive|
          expect { build_posts("posts(search: String @search): SearchPost #{directive}(model: \"SearchPost\")") }
            .to raise_error(Lighthouse::DefinitionError, /needs @all or @paginate on a root field/)
        end
        expect do
          build_posts('posts(search: String @search): SearchPost @find')
        end.to raise_error(Lighthouse::DefinitionError, /needs @all or @paginate/)
        expect { build_posts('posts(search: String @search): SearchPost') }.to raise_error(Lighthouse::DefinitionError, /needs @all or @paginate/)
      end

      it 'refuses a nested field, which pages a relation' do
        expect do
          build_schema(<<~GRAPHQL)
            type SearchPost { id: ID! related(search: String @search): [SearchPost!]! @paginate }
            type Query { posts: [SearchPost!]! @all }
          GRAPHQL
        end.to raise_error(Lighthouse::DefinitionError, /SearchPost.related\(search\): .*needs @all or @paginate on a root field/)
      end

      it "refuses a nested @paginate when the model: is another directive's: it still pages the parent's association" do
        expect do
          build_schema(<<~GRAPHQL)
            type SearchPost { id: ID! related(search: String @search): [SearchPost!]! @paginate @canModel(ability: "view", model: "SearchPost") }
            type Query { posts: [SearchPost!]! @all }
          GRAPHQL
        end.to raise_error(Lighthouse::DefinitionError, /needs @all or @paginate on a root field/)
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
