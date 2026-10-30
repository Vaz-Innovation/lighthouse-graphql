# frozen_string_literal: true

require 'spec_helper'

ActiveRecord::Schema.define do
  create_table :pg_search_documents, force: true do |t|
    t.string :searchable_type
    t.integer :searchable_id
    t.string :content
  end
end

# pg_search's document, as the gem defines it: one row for each record a multisearchable model keeps.
class TogetherSpecDocument < ApplicationRecord
  self.table_name = 'pg_search_documents'
  belongs_to :searchable, polymorphic: true
end

# A Searchkick model of a tenant's: its default scope, and the engine's where: for it.
class SearchkickTogetherPost < ApplicationRecord
  self.table_name = 'search_posts'
  default_scope { where(author_id: 1) }

  def self.searchkick_index = Struct.new(:name).new('search_posts_test')
  def self.searchkick_options = {}
  def self.search_where = { author_id: 1 }
end

# One whose default scope narrows what loads, which it does not tell the engine (no search_where).
class SearchkickUntoldPost < ApplicationRecord
  self.table_name = 'search_posts'
  default_scope { where(author_id: 1) }

  def self.searchkick_index = Struct.new(:name).new('search_posts_test')
  def self.searchkick_options = {}
end

# STI, through pg_search's multisearch: a subclass's documents hold its base class's name.
class TogetherItem < ApplicationRecord
  self.table_name = 'search_items'

  def self.pg_search_multisearchable_options = { against: [:title] }
end

class TogetherSpecialItem < TogetherItem; end

# A tenant's widgets: its default scope narrows what a search of it may answer.
class TogetherTenantWidget < ApplicationRecord
  self.table_name = 'widgets'
  default_scope { where(rank: 1) }

  def self.pg_search_multisearchable_options = { against: [:name] }
end

class SearchkickTogetherWidget < ApplicationRecord
  self.table_name = 'widgets'

  def self.searchkick_index = Struct.new(:name).new('widgets_test')
  def self.searchkick_options = {}
end

# An engine outside the database that searches models together, answering the records it was given.
class TogetherSpecEngine < FakeSearch::Engine
  attr_accessor :refused

  def searchable_together?(model) = searchable?(model)
  def together_error(model) = refused&.dig(model)
end

# Models searched together: the models of a union's or an interface's types, in one search.
RSpec.describe '@search over several models' do
  let(:engine_class) { TogetherSpecEngine }
  let(:records) { [SearchPost.create!(title: 'great post'), Widget.create!(name: 'great widget'), SearchPost.create!(title: 'great too')] }
  let(:engine) { engine_class.new([SearchPost, Widget], records) }

  let(:union_sdl) do
    <<~GRAPHQL
      union Found = SearchPost | Widget
      type SearchPost { id: ID! title: String! }
      type Widget { id: ID! name: String }
      type Query {
        everything(search: String! @search, authorId: Int @eq(key: "author_id")): [Found!]! @all
        paged(search: String! @search): [Found!]! @paginate
      }
    GRAPHQL
  end
  let(:selection) { '__typename ... on SearchPost { title } ... on Widget { name }' }

  before do
    SearchPost.delete_all
    Widget.delete_all
    Lighthouse::Config.search = engine
  end

  def run(schema, query) = schema.execute(query).to_h

  def names(result, field = 'everything')
    rows = result.dig('data', field)
    (rows.is_a?(Hash) ? rows['data'] : rows).map { |row| [row['__typename'], row['title'] || row['name']] }
  end

  it "searches the union's models in one search, and answers each record as its model's type, in the engine's order" do
    result = run(build_schema(union_sdl), %({ everything(search: "great") { #{selection} } }))

    expect(names(result)).to eq([['SearchPost', 'great post'], ['Widget', 'great widget'], ['SearchPost', 'great too']])
    expect(engine.requests.size).to eq(1)
    expect([engine.query.models, engine.query.model, engine.query.term]).to eq([[SearchPost, Widget], nil, 'great'])
  end

  it "searches an interface's models, the object types that implement it" do
    schema = build_schema(<<~GRAPHQL)
      interface Named { id: ID! }
      type SearchPost implements Named { id: ID! title: String! }
      type Widget implements Named { id: ID! name: String }
      type Query { named(search: String! @search): [Named!]! @all }
    GRAPHQL

    expect(names(run(schema, %({ named(search: "great") { #{selection} } })), 'named').map(&:first)).to eq(%w[SearchPost Widget SearchPost])
    expect(engine.query.models).to eq([SearchPost, Widget])
  end

  it 'pages the search of the models, with the total the engine counted' do
    result = run(build_schema(union_sdl), %({ paged(first: 2, page: 2, search: "great") { data { #{selection} } paginatorInfo { total } } }))

    expect(names(result, 'paged')).to eq([['SearchPost', 'great too']])
    expect(result.dig('data', 'paged', 'paginatorInfo', 'total')).to eq(3)
  end

  it 'pages a connection and a simple paginator of the models, by the positions of the hits' do
    schema = build_schema(union_sdl.sub('paged(search: String! @search): [Found!]! @paginate', <<~GRAPHQL))
      feed(search: String! @search): [Found!]! @paginate(type: CONNECTION)
      simple(search: String! @search): [Found!]! @paginate(type: SIMPLE)
    GRAPHQL

    feed = run(schema,
               %({ feed(first: 2, search: "great") { edges { cursor node { #{selection} } } pageInfo { hasNextPage endCursor } } }))['data']['feed']
    rest = run(schema, %({ feed(first: 2, after: "#{feed['pageInfo']['endCursor']}", search: "great") { edges { node { #{selection} } } } }))
    simple = run(schema, %({ simple(first: 2, page: 2, search: "great") { data { #{selection} } paginatorInfo { hasMorePages } } }))['data']['simple']

    expect(feed['edges'].map { |edge| edge.dig('node', '__typename') }).to eq(%w[SearchPost Widget])
    expect(feed['pageInfo']['hasNextPage']).to be(true)
    expect(rest.dig('data', 'feed', 'edges').map { |edge| edge.dig('node', 'title') }).to eq(['great too'])
    expect(simple).to eq('data' => [{ '__typename' => 'SearchPost', 'title' => 'great too' }], 'paginatorInfo' => { 'hasMorePages' => false })
  end

  it 'reads as many records as @all asks for, from its offset' do
    schema = build_schema(union_sdl.sub('everything(search: String! @search', 'everything(first: Int, offset: Int, search: String! @search'))

    result = run(schema, %({ everything(first: 1, offset: 1, search: "great") { #{selection} } }))

    expect(names(result)).to eq([['Widget', 'great widget']])
    expect(engine.requests.last.slice(:offset, :limit)).to eq(offset: 1, limit: 1)
  end

  it "takes a model's type @model names, and narrows the search with what the engine applies (@eq)" do
    schema = build_schema(<<~GRAPHQL)
      union Found = Article | Widget
      type Article @model(class: "SearchPost") { title: String! }
      type Widget { name: String }
      type Query { everything(search: String! @search, authorId: Int @eq(key: "author_id")): [Found!]! @all }
    GRAPHQL

    run(schema, '{ everything(search: "great", authorId: 3) { __typename } }')

    expect([engine.query.models, engine.query.wheres]).to eq([[SearchPost, Widget], [['author_id', 3]]])
  end

  it 'refuses an argument the engine cannot apply, as a search of one model does' do
    schema = build_schema(union_sdl.sub('authorId: Int @eq(key: "author_id")', 'authorId: Int @where(key: "author_id", operator: ">")'))

    expect(run(schema, '{ everything(search: "x", authorId: 1) { __typename } }')['errors'].pluck('message'))
      .to eq(['Found arg builder arguments that do not work with @search: @where on authorId.'])
  end

  it 'checks each record the search finds with @canQuery, by its own policy' do
    Lighthouse::Config.authorizer = ->(_user, record, _ability) { !record.is_a?(Widget) }
    schema = build_schema(union_sdl.sub('[Found!]! @all', '[Found!]! @all @canQuery(ability: "view")'))

    expect(run(schema, '{ everything(search: "great") { __typename } }')['errors'].pluck('message')).to eq(['This action is unauthorized.'])
    engine.instance_variable_set(:@records, records.grep(SearchPost))
    expect(run(schema, '{ everything(search: "great") { __typename } }').dig('data', 'everything').size).to eq(2)
  end

  it 'searches one model when the directive names it, as any field' do
    schema = build_schema(union_sdl.sub('[Found!]! @all', '[Found!]! @all(model: "SearchPost")'))

    run(schema, '{ everything(search: "great") { __typename } }')

    expect([engine.query.model, engine.query.models]).to eq([SearchPost, nil])
  end

  describe 'at build time' do
    def build(field, types: 'union Found = SearchPost | Widget')
      build_schema("#{types} type SearchPost { id: ID! title: String } type Widget { id: ID! name: String } type Query { #{field} }")
    end

    it 'needs one @search, on a non-null argument: there is no table to list without one' do
      expect { build(:'f(search: String @search): [Found!]! @all') }
        .to raise_error(Lighthouse::DefinitionError, /Query.f\(search\): a field that searches Found's models together needs its search/)
      expect { build(:'f(search: String! @search, other: String @search): [Found!]! @all') }
        .to raise_error(Lighthouse::DefinitionError, /needs its search: one @search/)
    end

    it 'refuses `within:`, which names one index or scope' do
      expect { build(:'f(search: String! @search(within: "posts")): [Found!]! @all') }
        .to raise_error(Lighthouse::DefinitionError, /`within:` names one model's index or scope/)
    end

    it 'needs @all or @paginate on a root field' do
      expect { build(:'f(search: String! @search): Found @first') }
        .to raise_error(Lighthouse::DefinitionError, /Found has several models, which only @all or @paginate on a root field search together/)
      expect do
        build_schema(<<~GRAPHQL)
          union Found = SearchPost | Widget
          type SearchPost { id: ID! found(search: String! @search): [Found!]! @all }
          type Widget { id: ID! }
          type Query { posts: [SearchPost!]! @all }
        GRAPHQL
      end.to raise_error(Lighthouse::DefinitionError, /SearchPost.found\(search\): Found has several models/)
    end

    it 'needs every type to be a model' do
      expect { build(:'f(search: String! @search): [Found!]! @all', types: 'union Found = SearchPost | Widget | Nothing type Nothing { id: ID! }') }
        .to raise_error(Lighthouse::DefinitionError, /Found's type Nothing is no model's: give it @model\(class:\)/)
    end

    it 'needs one engine that searches every model together, as it is' do
      Lighthouse::Config.search = engine_class.new([SearchPost])
      expect { build(:'f(search: String! @search): [Found!]! @all') }
        .to raise_error(Lighthouse::DefinitionError, /no engine searches Found's models together: SearchPost \(.*\), Widget \(not searchable\)/)

      engine.refused = { Widget => 'Widget needs search_where' }
      Lighthouse::Config.search = engine
      expect { build(:'f(search: String! @search): [Found!]! @all') }.to raise_error(Lighthouse::DefinitionError, /: Widget needs search_where\.\z/)
    end

    it "refuses what one model's search would apply, and a search of several cannot" do
      {
        'f(search: String! @search): [Found!]! @all(scopes: ["recent"])' => /cannot apply `scopes:` to models searched together/,
        'f(search: String! @search): [Found!]! @all @builder(class: "Published")' => /cannot apply @builder to models searched together/,
        'f(search: String! @search, trashed: Trashed @trashed): [Found!]! @all' => /@trashed on trashed cannot filter models searched together/,
        'f(search: String! @search, minId: Int = 1 @where(key: "id", operator: ">")): [Found!]! @all' => /@where on minId, whose default/,
        'f(search: String! @search): [Found!]! @all @canQuery(ability: "view", scopes: ["recent"])' => /the `scopes:` of @canQuery cannot narrow/
      }.each { |field, error| expect { build(field) }.to raise_error(Lighthouse::DefinitionError, error), field }
    end
  end

  describe 'with Searchkick' do
    let(:searches) { [] }
    let(:query) do
      Lighthouse::Search::Query.new(nil, 'great', models: [SearchkickTogetherPost, SearchkickTogetherWidget]).where(:title, 'great post')
    end

    before do
      log = searches
      searchkick = Module.new
      searchkick.define_singleton_method(:search) do |term, **options|
        (log << [term, options]) && FakeSearch::Response.new([SearchkickTogetherWidget.new(name: 'w')], 1)
      end
      stub_const('Searchkick', searchkick)
    end

    it 'searches the indices of the models in one request, each model narrowed in its own index' do
      records, total = Lighthouse::Search::Searchkick.new.page(query, offset: 10, limit: 5)
      term, options = searches.last

      expect([records.map(&:name), total, term]).to eq([['w'], 1, 'great'])
      expect(options.except(:scope_results)).to eq(
        models: [SearchkickTogetherPost, SearchkickTogetherWidget], load: true, body_options: { track_total_hits: true }, offset: 10, limit: 5,
        where: { title: 'great post', _or: [{ _index: 'search_posts_test', author_id: 1 }, { _index: 'widgets_test' }] }
      )
    end

    it "loads each model's records through its own narrowing" do
      Lighthouse::Search::Searchkick.new.page(query, offset: 0, limit: 5)
      loading = searches.last.last[:scope_results]

      # Searchkick calls it with the model itself, or a relation of it when one is in scope.
      expect(loading.call(SearchkickTogetherPost).to_sql).to include('"search_posts"."title" = \'great post\'')
      expect(loading.call(SearchkickTogetherPost.where(id: 1)).to_sql).to include('"search_posts"."title" = \'great post\'')
      expect(loading.call(SearchkickTogetherWidget)).to equal(SearchkickTogetherWidget)
    end

    it 'refuses a model whose default scope narrows what loads without search_where, as alone' do
      expect(Lighthouse::Search::Searchkick.new.together_error(SearchkickTogetherWidget)).to be_nil
      expect(Lighthouse::Search::Searchkick.new.together_error(SearchkickUntoldPost)).to include('Define SearchkickUntoldPost.search_where')
    end
  end

  describe 'with pg_search' do
    let(:adapter) { Lighthouse::Search::PgSearch.new }
    let(:post_model) do
      Class.new(SearchPost) do
        def self.name = 'SearchPost'
        def self.pg_search_multisearchable_options = { against: [:title] }
      end
    end

    before do
      stub_const('PgSearch::Model', FakeSearch::PgSearchModel)
      stub_const('PgSearch::Document', TogetherSpecDocument)
      PgSearch.define_singleton_method(:multisearch) { |term| PgSearch::Document.where('content LIKE ?', "%#{term}%").order(:id) }
      TogetherSpecDocument.delete_all
    end

    def document(record, content)
      TogetherSpecDocument.create!(searchable_type: record.class.polymorphic_name, searchable_id: record.id, content: content)
    end

    it "searches multisearch's documents, ranked together, each one's record selected by its model's relation" do
      mine = SearchPost.create!(title: 'great mine', author_id: 3)
      other = SearchPost.create!(title: 'great other', author_id: 4)
      widget = Widget.create!(name: 'great widget')
      [[mine, 'great mine'], [widget, 'great widget'], [other, 'great other'], [Widget.create!(name: 'x'), 'nothing']].each { |pair| document(*pair) }
      query = Lighthouse::Search::Query.new(nil, 'great', models: [post_model, Widget]).where(:author_id, 3)

      records, total = adapter.page(query, offset: 0, limit: 10)

      # Widget has no author_id: the condition matches none of its records, as in an index that does not hold it.
      expect([records.map(&:id), total]).to eq([[mine.id], 1])
      expect(adapter.page(Lighthouse::Search::Query.new(nil, 'great', models: [post_model, Widget]), offset: 1, limit: 1))
        .to eq([[widget], 3])
    end

    it 'answers nil where a record its document holds is gone, keeping the positions, and counts only what loads' do
      gone = SearchPost.create!(title: 'great gone')
      kept = Widget.create!(name: 'great kept')
      document(gone, 'great gone')
      document(kept, 'great kept')
      gone.delete

      records, total = adapter.page(Lighthouse::Search::Query.new(nil, 'great', models: [post_model, Widget]), offset: 0, limit: 10)

      expect([records, total]).to eq([[kept], 1])
    end

    it 'searches an STI subclass and its base class, whose documents hold the base class name, each record once' do
      plain = TogetherItem.create!(title: 'great plain')
      special = TogetherSpecialItem.create!(title: 'great special')
      [plain, special].each { |item| TogetherSpecDocument.create!(searchable_type: 'TogetherItem', searchable_id: item.id, content: item.title) }

      specials = adapter.page(Lighthouse::Search::Query.new(nil, 'great', models: [TogetherSpecialItem, Widget]), offset: 0, limit: 10)
      both = adapter.page(Lighthouse::Search::Query.new(nil, 'great', models: [TogetherItem, TogetherSpecialItem]), offset: 0, limit: 10)

      expect(specials).to eq([[special], 1])
      expect([both.first.map(&:id), both.last]).to eq([[plain.id, special.id], 2])
      expect(both.first.last).to be_a(TogetherSpecialItem)
    end

    # Generated cases: records of two models, one of a tenant's (a default scope), their documents,
    # some stale (a record gone, or one the tenant's scope leaves out), and an @eq. Whatever the
    # page, the search answers only records its models' relations select, never one twice, in rank
    # order, and its total counts what loads, every page together being all of it.
    it 'answers only what each model selects, its total what loads, its pages all of it once' do
      random = Random.new(Integer(ENV.fetch('SEARCH_TOGETHER_SEED', '20261030')))
      Integer(ENV.fetch('SEARCH_TOGETHER_CASES', '60')).times do |kase|
        TogetherSpecDocument.delete_all
        SearchPost.delete_all
        Widget.delete_all
        records = Array.new(random.rand(0..12)) do
          if random.rand < 0.5
            SearchPost.create!(title: "great #{random.rand(3)}", author_id: random.rand(1..3))
          else
            TogetherTenantWidget.unscoped.create!(name: "great #{random.rand(3)}", rank: random.rand(1..2))
          end
        end
        records.shuffle(random: random).each do |record|
          TogetherSpecDocument.create!(searchable_type: record.class.polymorphic_name, searchable_id: record.id,
                                       content: random.rand < 0.85 ? 'great' : 'other')
        end
        records.sample(random.rand(0..2), random: random).each(&:delete)
        author = random.rand < 0.4 ? random.rand(1..3) : nil
        query = lambda {
          Lighthouse::Search::Query.new(nil, 'great', models: [post_model, TogetherTenantWidget]).tap do |q|
            q.where(:author_id, author) if author
          end
        }

        loadable = TogetherSpecDocument.where('content LIKE ?', '%great%').order(:id).filter_map do |document|
          model = document.searchable_type == 'SearchPost' ? SearchPost : TogetherTenantWidget
          record = model.find_by(id: document.searchable_id)
          next unless record
          next if author && !(record.is_a?(SearchPost) && record.author_id == author)

          [document.searchable_type, record.id]
        end
        size = random.rand(1..4)
        pages = (0..(loadable.size / size)).map { |page| adapter.page(query.call, offset: page * size, limit: size) }

        context = "case #{kase}: author #{author.inspect}, #{records.size} records"
        expect(pages.map(&:last).uniq).to eq([loadable.size]), context
        answered = pages.flat_map(&:first)
        expect(answered).to all(be_present), context
        expect(answered.map { |record| [record.class.polymorphic_name, record.id] }).to eq(loadable), context
        expect(answered.grep(TogetherTenantWidget).map(&:rank).uniq - [1]).to eq([]), context
      end
    end

    it 'needs multisearchable models, and refuses the Searchkick options an @builder set' do
      expect(adapter.together_error(Widget)).to include('Widget keeps no pg_search multisearch documents')
      expect(adapter.together_error(post_model)).to be_nil
      query = Lighthouse::Search::Query.new(nil, 'x', models: [post_model])
      query.options[:scope_results] = ->(records) { records }

      expect do
        adapter.page(query, offset: 0,
                            limit: 1)
      end.to raise_error(Lighthouse::DefinitionError, /takes no option of Searchkick's, which an @builder set: scope_results/)
    end
  end
end
