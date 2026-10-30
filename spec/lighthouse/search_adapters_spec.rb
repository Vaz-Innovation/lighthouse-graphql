# frozen_string_literal: true

require 'spec_helper'

# The adapters of the two gems, without the gems: what each asks of them and how it detects its model.
# example/ runs them against OpenSearch and PostgreSQL.
RSpec.describe 'search adapters' do
  describe Lighthouse::Search::Searchkick do
    subject(:adapter) { described_class.new }

    let(:query) { Lighthouse::Search::Query.new(SearchkickPost, 'milk') }
    let(:reported) { [] }

    before do
      stub_const('Searchkick', Module.new)
      SearchkickPost.searches = []
      SearchkickPost.indexed = %w[title deleted_at]
      Lighthouse::Config.on_error = ->(error, _context) { reported << error.message }
    end

    def searched = SearchkickPost.searches.last

    it 'searches the models that call searchkick, outside the database' do
      expect(adapter.searchable?(SearchkickPost)).to be(true)
      expect(adapter.searchable?(SearchPost)).to be(false)
      expect(adapter).not_to be_relational
    end

    it 'does not search without the gem' do
      hide_const('Searchkick')

      expect(adapter.searchable?(SearchkickPost)).to be(false)
    end

    it 'asks for a page of loaded records, and reads the total from the same response' do
      query.where(:author_id, 3).options[:fields] = ['title']

      records, total = adapter.page(query, offset: 20, limit: 10)
      expect([records.map(&:title), total]).to eq([%w[a b], 7])
      expect(SearchkickPost.searches.map { |term, options| [term, options.except(:scope_results)] }).to eq(
        [['milk', { where: { author_id: 3 }, fields: ['title'], load: true, body_options: { track_total_hits: true }, offset: 20, limit: 10 }]]
      )
    end

    it 'loads the records through the conditions it can apply in the database too, so a stale index cannot answer one that no longer matches' do
      query.where(:author_id, 3).where(:title, %w[a b]).where(:indexed_only, 1).where(:author_id, { gt: 1 })
      query.trashed = :without

      adapter.page(query, offset: 0, limit: 1)

      sql = searched.last[:scope_results].call(SearchkickPost).to_sql
      expect(sql).to include('"search_posts"."author_id" = 3', %("search_posts"."title" IN ('a', 'b')), '"search_posts"."deleted_at" IS NULL')
      expect(sql).not_to include('indexed_only')
    end

    it 'always asks for the exact total, which Elasticsearch and OpenSearch 7+ stop counting at 10,000, and the app cannot ask otherwise' do
      query.options[:body_options] = { min_score: 1 }
      adapter.page(query, offset: 0, limit: 1)
      expect(searched.last[:body_options]).to eq(min_score: 1, track_total_hits: true)

      [{ body_options: { track_total_hits: 50_000 } }, { body_options: { 'track_total_hits' => false } }].each do |options|
        query.options.replace(options)
        expect { adapter.page(query, offset: 0, limit: 1) }.to raise_error(Lighthouse::DefinitionError, /body_options cannot set track_total_hits/)
      end
    end

    it "refuses an @builder's options that decide what loads, how it pages or what it counts" do
      [{ load: false }, { 'index_name' => 'other' }, { models: [SearchPost] }, { unscope: true }, { track_total_hits: false },
       { page: 2 }, { body: {} }].each do |options|
        query.options.replace(options)
        expect { adapter.page(query, offset: 0, limit: 1) }
          .to raise_error(Lighthouse::DefinitionError, /an @builder may not set `#{options.keys.first}:` of Searchkick's search/)
      end
      %i[query size from terminate_after].each do |key|
        query.options.replace(body_options: { key => 1 })
        expect { adapter.page(query, offset: 0, limit: 1) }.to raise_error(Lighthouse::DefinitionError, /body_options may not set #{key}/)
      end
    end

    it "keeps the database's checks after an @builder's scope_results, which runs first and cannot widen what loads" do
      query.where(:author_id, 3)
      query.options[:scope_results] = ->(records) { records.unscoped }

      adapter.page(query, offset: 0, limit: 1)

      expect(searched.last[:scope_results].call(SearchkickPost).to_sql).to include('"search_posts"."author_id" = 3')
    end

    it 'checks again in the database only the values it compares as the engine does: scalars, lists and ranges of them' do
      query.where(:author_id, { gt: 3 }).where(:author_id, /1/).where(:author_id, [{ gt: 1 }]).where(:author_id, 1..1_000_000_000)
           .where(:deleted_at, Time.utc(2026)..).where(:title, %w[a b]).where(:title, :c)

      adapter.page(query, offset: 0, limit: 1)

      sql = searched.last[:scope_results].call(SearchkickPost).to_sql
      expect(sql).to include('BETWEEN 1 AND 1000000000', %("search_posts"."deleted_at" >= '2026-01-01), %(IN ('a', 'b')), %("title" = 'c'))
      expect(sql).not_to include('gt', '{')
    end

    it 'refuses a total the engine did not count to the end' do
      response = Struct.new(:hits, :total_count, :response) { def with_hit = [] }
                       .new([], 10_000, { 'hits' => { 'total' => { 'value' => 10_000, 'relation' => 'gte' } } })
      allow(SearchkickPost).to receive(:searchkick_search).and_return(response)

      expect { adapter.page(query, offset: 0, limit: 1) }.to raise_error(Lighthouse::DefinitionError, /counted gte 10000 matches, not every one/)
    end

    it "ANDs a builder's where and the @eq conditions on one column, whatever the keys' type, rather than overwrite" do
      query.options[:where] = { 'author_id' => [1, 2], 'published' => true }
      query.where(:author_id, 3).where('author_id', 4)

      adapter.page(query, offset: 0, limit: 1)

      expect(searched.last[:where]).to eq(_and: [{ author_id: [1, 2], published: true }, { author_id: 3 }, { author_id: 4 }])
    end

    it 'places each record at its own hit, when hits of two indices share an id' do
      hits = [{ '_index' => 'posts', '_id' => '1' }, { '_index' => 'drafts', '_id' => '1' }]
      draft = SearchkickPost.new(title: 'draft')
      response = Struct.new(:hits, :total_count, :loaded) { def with_hit = [[loaded, hits[1]]] }.new(hits, 2, draft)
      allow(SearchkickPost).to receive(:searchkick_search).and_return(response)

      expect(adapter.page(query, offset: 0, limit: 2)).to eq([[nil, draft], 2])
    end

    it "refuses an STI subclass searching its parent's index, unless Searchkick filters it by type or search_where does" do
      expect(adapter.model_error(SearchkickItem)).to be_nil
      expect(adapter.model_error(SearchkickSpecialItem))
        .to include("SearchkickSpecialItem's STI type, in SearchkickItem's index without `inheritance: true`, narrows what a search loads")
      allow(SearchkickSpecialItem).to receive(:searchkick_options).and_return(inheritance: true)
      expect(adapter.model_error(SearchkickSpecialItem)).to be_nil
      allow(SearchkickSpecialItem).to receive_messages(searchkick_options: {}, search_where: { type: 'SearchkickSpecialItem' })
      expect(adapter.model_error(SearchkickSpecialItem)).to be_nil
    end

    it 'searches the index within: names, and merges the where of a builder' do
      query = Lighthouse::Search::Query.new(SearchkickPost, 'milk', 'other_index')
      query.options[:where] = { published: true }
      query.where('author_id', 3)

      adapter.page(query, offset: 0, limit: 1)

      expect(searched.last).to include(where: { published: true, author_id: 3 }, index_name: 'other_index', offset: 0, limit: 1)
    end

    describe 'the result window' do
      let(:indices) { double('indices') } # rubocop:disable RSpec/VerifiedDoubles -- the engine client's, which the suite does not load

      def settings_answer(&answer)
        client = Struct.new(:indices).new(indices)
        Searchkick.define_singleton_method(:client) { client }
        allow(SearchkickPost).to receive(:searchkick_index).and_return(Struct.new(:name).new('search_posts'))
        allow(indices).to receive(:get_settings, &answer)
      end

      def index_settings(*windows)
        windows.each_with_index.to_h do |window, at|
          ["search_posts_#{at}", { 'settings' => { 'index' => { 'max_result_window' => window }.compact } }]
        end
      end

      it "is the index's max_result_window on the engine: the smallest of an alias's indices, else the engines' default" do
        allow(SearchkickPost).to receive(:searchkick_options).and_return(max_result_window: 50_000)
        settings_answer { index_settings('5000') }
        expect(described_class.new.result_window(query)).to eq(5_000)
        settings_answer { index_settings('20000', '3000') }
        expect(described_class.new.result_window(query)).to eq(3_000)
        settings_answer { index_settings(nil) }
        expect(described_class.new.result_window(query)).to eq(10_000)
      end

      it 'reads the settings of the index within: names, else takes 10,000 for it when they cannot be read' do
        settings_answer { |index:| index == 'other_index' ? index_settings('700') : raise('no such index') }
        expect(adapter.result_window(Lighthouse::Search::Query.new(SearchkickPost, 'milk', 'other_index'))).to eq(700)
        allow(SearchkickPost).to receive(:searchkick_options).and_return(max_result_window: 50_000)
        expect(adapter.result_window(Lighthouse::Search::Query.new(SearchkickPost, 'milk', 'missing_index'))).to eq(10_000)
      end

      it "takes the model's max_result_window, a billion with deep_paging, else the engines' default, when the settings cannot be read" do
        expect(described_class.new.result_window(query)).to eq(10_000)
        allow(SearchkickPost).to receive(:searchkick_options).and_return(deep_paging: true)
        expect(described_class.new.result_window(query)).to eq(1_000_000_000)
        allow(SearchkickPost).to receive(:searchkick_options).and_return(max_result_window: 50_000, deep_paging: true)
        expect(described_class.new.result_window(query)).to eq(50_000)
        allow(SearchkickPost).to receive(:searchkick_options).and_return(settings: { index: { max_result_window: 20_000 } })
        expect(described_class.new.result_window(query)).to eq(20_000)
        allow(SearchkickPost).to receive(:searchkick_options).and_return(settings: { 'index' => { 'max_result_window' => 50_000 } })
        expect(described_class.new.result_window(query)).to eq(50_000)
        allow(SearchkickPost).to receive(:searchkick_options).and_return('settings' => { 'index.max_result_window' => 30_000 })
        expect(described_class.new.result_window(query)).to eq(30_000)
      end

      it 'reads the settings once in INDEX_READ_TTL seconds, a failed read once in FAILED_READ_TTL, and again for a reloaded class' do
        reloaded = Class.new(SearchkickPost) { def self.name = 'SearchkickPost' }
        answers = [-> { raise 'no index yet' }, -> { index_settings('5000') }, -> { index_settings('4000') }, -> { index_settings('3000') }]
        settings_answer { answers.shift.call }
        allow(reloaded).to receive(:searchkick_index).and_return(Struct.new(:name).new('search_posts'))
        now = 0
        timed = described_class.new(index: Lighthouse::Search::Searchkick::Index.new(clock: -> { now }))

        windows = [0, 4, 5, 30, 64, 65].map { |at| (now = at) && timed.result_window(query) }
        windows << timed.result_window(Lighthouse::Search::Query.new(reloaded, 'milk'))

        expect(windows).to eq([10_000, 10_000, 5_000, 5_000, 5_000, 4_000, 3_000])
        expect(indices).to have_received(:get_settings).exactly(4).times
      end

      it "turns the engine's refusal of a page past it into an error the client reads" do
        stub_const('Searchkick::InvalidQueryError', Class.new(StandardError))
        message = '[400] {"error":{"reason":"Result window is too large, from + size must be less than or equal to: [500] but was [510]. ' \
                  'This limit can be set by changing the [index.max_result_window] index level setting."}}'
        allow(SearchkickPost).to receive(:searchkick_search).and_raise(Searchkick::InvalidQueryError, message)

        expect { adapter.page(query, offset: 500, limit: 10) }
          .to raise_error(GraphQL::ExecutionError, /The search reads no further than the index.max_result_window of SearchkickPost/)
      end

      it 'leaves the other errors of the engine alone' do
        stub_const('Searchkick::InvalidQueryError', Class.new(StandardError))
        allow(SearchkickPost).to receive(:searchkick_search).and_raise(Searchkick::InvalidQueryError, 'Bad mapping - run SearchkickPost.reindex')

        expect { adapter.page(query, offset: 0, limit: 10) }.to raise_error(Searchkick::InvalidQueryError, /Bad mapping/)
      end
    end

    describe 'trashed records' do
      def where_of(trashed, adapter = self.adapter)
        query.trashed = trashed
        adapter.page(query, offset: 0, limit: 1)
        searched.last[:where]
      end

      it 'filters ONLY on a value in the column and WITHOUT on none; WITH leaves the index as it is' do
        expect(where_of(:only)).to eq(deleted_at: { not: nil })
        expect(where_of(:without)).to eq(deleted_at: nil)
        expect(where_of(:with)).to eq({})
      end

      it 'filters on the column Config.soft_deletes names, the one source of it' do
        SearchkickPost.indexed = %w[archived_at]
        Lighthouse::Config.soft_deletes = Lighthouse::Support::SoftDeletes::Column.new(:archived_at)

        expect(where_of(:only)).to eq(archived_at: { not: nil })
      end

      it 'does not need the column for WITH, which filters nothing' do
        SearchkickPost.indexed = %w[title]

        expect(where_of(:with)).to eq({})
      end

      it 'refuses a model that does not index the column' do
        SearchkickPost.indexed = %w[title]

        expect { where_of(:only) }.to raise_error(GraphQL::ExecutionError, /SearchkickPost's index does not hold deleted_at/)
      end

      it "reads what the model's search_data holds once, and again for the class code reloading makes" do
        reloaded = Class.new(SearchkickPost) { def self.name = 'SearchkickPost' }
        reloaded.searches = []
        reloaded.indexed = %w[deleted_at]
        reads = Hash.new(0)
        count = ->(original, *args) { (reads[original.receiver.class] += 1) && original.call(*args) }
        allow_any_instance_of(SearchkickPost).to receive(:search_data).and_wrap_original(&count) # rubocop:disable RSpec/AnyInstance

        2.times { where_of(:only) }
        adapter.page(Lighthouse::Search::Query.new(reloaded, 'milk').tap { |again| again.trashed = :only }, offset: 0, limit: 1)

        expect(reads).to eq(SearchkickPost => 1, reloaded => 1)
      end

      describe 'on a model whose default scope hides its trashed records' do
        let(:query) { Lighthouse::Search::Query.new(SearchkickHiddenPost, 'milk') }

        before { SearchkickHiddenPost.searches = [] }

        it 'filters the engine on the records that are not trashed when @trashed does not say, as they alone load' do
          wheres = [nil, :only, :with].map do |trashed|
            query.trashed = trashed
            adapter.page(query, offset: 0, limit: 1)
            SearchkickHiddenPost.searches.last[:where]
          end

          expect(wheres).to eq([{ deleted_at: nil }, { deleted_at: { not: nil } }, {}])
        end

        it 'refuses a search_where that names the soft-delete column, at any depth, which could not yield to @trashed' do
          [{ deleted_at: nil }, { _or: [{ author_id: 1 }, { 'deleted_at' => nil }] },
           { _and: [{ _not: { deleted_at: { not: nil } } }] }].each do |where|
            allow(SearchkickHiddenPost).to receive(:search_where).and_return(where)

            expect { adapter.page(query, offset: 0, limit: 1) }
              .to raise_error(Lighthouse::DefinitionError,
                              /SearchkickHiddenPost.search_where names deleted_at, the column @trashed and Lighthouse filter/)
          end
        end
      end

      describe 'when search_data cannot run on a blank record' do
        let(:mappings) { { 'search_posts_1' => { 'mappings' => { 'properties' => { 'title' => {}, 'deleted_at' => {} } } } } }
        let(:indices) { double('indices') } # rubocop:disable RSpec/VerifiedDoubles -- the engine client's, which the suite does not load

        before do
          SearchkickPost.indexed = :raise
          client = Struct.new(:indices).new(indices)
          Searchkick.define_singleton_method(:client) { client }
          allow(SearchkickPost).to receive(:searchkick_index).and_return(Struct.new(:name).new('search_posts'))
        end

        def mapping_answers(&answer)
          allow(indices).to receive(:get_mapping, &answer)
        end

        it "reads the columns from the index's mapping on the engine, once" do
          mapping_answers { mappings }

          2.times { expect(where_of(:only)).to eq(deleted_at: { not: nil }) }
          expect(indices).to have_received(:get_mapping).with(index: 'search_posts').once
        end

        it 'refuses a column the mapping does not hold' do
          mappings['search_posts_1']['mappings']['properties'].delete('deleted_at')
          mapping_answers { mappings }

          expect { where_of(:only) }.to raise_error(GraphQL::ExecutionError, /SearchkickPost's index does not hold deleted_at/)
        end

        it 'reads the mapping again once a read is INDEX_READ_TTL seconds old, a failed one FAILED_READ_TTL: a reindex adds or removes a column' do
          without = -> { { 'search_posts_1' => { 'mappings' => { 'properties' => { 'title' => {} } } } } }
          answers = [-> { raise 'no index yet' }, without, -> { mappings }, without]
          mapping_answers { answers.shift.call }
          now = 0
          timed = described_class.new(index: Lighthouse::Search::Searchkick::Index.new(clock: -> { now }))
          outcome = lambda do |at|
            now = at
            where_of(:only, timed).then { 'filters' }
          rescue GraphQL::ExecutionError => e
            e.message[/cannot tell|does not hold/]
          end

          expect([0, 4, 5, 64, 65, 100, 125].map(&outcome))
            .to eq(['cannot tell', 'cannot tell', 'does not hold', 'does not hold', 'filters', 'filters', 'does not hold'])
          expect(indices).to have_received(:get_mapping).exactly(4).times
        end

        it 'refuses when it cannot tell, naming why, rather than filter on a column the index may not hold; and reports the failure once' do
          mapping_answers { raise 'security_exception: action [indices:admin/mappings/get] is unauthorized' }

          2.times do
            expect { where_of(:only) }.to raise_error(GraphQL::ExecutionError) do |error|
              expect(error.message).to include("cannot tell whether SearchkickPost's index holds deleted_at")
                .and include('(RuntimeError: security_exception: action [indices:admin/mappings/get] is unauthorized; ' \
                             'reading it needs the view_index_metadata privilege on the index)')
            end
          end
          expect(reported).to eq(['security_exception: action [indices:admin/mappings/get] is unauthorized'])
        end

        it 'filters out the trashed records a default scope hides when it cannot tell, as that filter holds either way' do
          mapping_answers { raise 'no index' }
          hidden = Lighthouse::Search::Query.new(SearchkickHiddenPost, 'milk')
          allow(SearchkickHiddenPost).to receive(:searchkick_index).and_return(Struct.new(:name).new('search_posts'))
          allow_any_instance_of(SearchkickHiddenPost).to receive(:search_data).and_raise('needs a record') # rubocop:disable RSpec/AnyInstance

          adapter.page(hidden, offset: 0, limit: 1)

          expect(SearchkickHiddenPost.searches.last[:where]).to eq(deleted_at: nil)
        end

        it "reads the mapping of the index within: names, never the model's search_data, which tells its own index" do
          SearchkickPost.indexed = %w[title deleted_at]
          mapping_answers { |index:| index == 'archive' ? { 'archive_1' => { 'mappings' => { 'properties' => { 'title' => {} } } } } : mappings }
          archived = Lighthouse::Search::Query.new(SearchkickPost, 'milk', 'archive').tap { |again| again.trashed = :without }

          expect { adapter.page(archived, offset: 0, limit: 1) }
            .to raise_error(GraphQL::ExecutionError, /the index archive does not hold deleted_at, which @trashed filters the search on/)
          expect(where_of(:without)).to eq(deleted_at: nil)
        end
      end
    end
  end

  describe Lighthouse::Search::PgSearch do
    subject(:adapter) { described_class.new }

    before { stub_const('PgSearch::Model', FakeSearch::PgSearchModel) }

    it 'searches the models that include PgSearch::Model and have the scope, in the database' do
      expect(adapter.searchable?(PgSearchPost)).to be(true)
      expect(adapter.searchable?(PgSearchPost, 'by_title')).to be(true)
      expect(adapter.searchable?(PgSearchPost, 'nope')).to be(false)
      expect(adapter.searchable?(SearchPost)).to be(false)
      expect(adapter).to be_relational
    end

    it 'does not search without the gem' do
      hide_const('PgSearch')

      expect(adapter.searchable?(PgSearchPost)).to be(false)
    end

    it "drops pg_search's primary-key tie-break, a node of its own in 2.4 and the end of the rank's literal in 2.3, and sorts by rank first" do
      order_of = ->(index) { adapter.scope(PgSearchPost.order(:author_id), Lighthouse::Search::Query.new(PgSearchPost, 'milk', index)).to_sql[/ORDER BY .*\z/] }

      expect(order_of.call('ranked24')).to eq('ORDER BY "pg_search_1"."rank" DESC, "search_posts"."author_id" ASC')
      expect(order_of.call('ranked23')).to eq('ORDER BY pg_search_1.rank DESC, "search_posts"."author_id" ASC')
      expect(order_of.call('ranked23_within')).to eq('ORDER BY pg_search_1.rank DESC, search_posts.title DESC, "search_posts"."author_id" ASC')
    end

    it "sorts by rank before the model's default order and its search_results scope's" do
      query = Lighthouse::Search::Query.new(PgSearchOrderedPost, 'milk', 'ranked24')

      expect(adapter.scope(PgSearchOrderedPost.all, query).to_sql[/ORDER BY .*\z/])
        .to eq('ORDER BY "pg_search_1"."rank" DESC, "search_posts"."title" DESC, "search_posts"."author_id" DESC')
    end

    it "takes only pg_search's own scopes, not another gem's method of the name (Searchkick's `search`)" do
      expect(adapter.searchable?(SearchkickSearchPost)).to be(false)
      expect(adapter.named?(SearchkickSearchPost, 'search')).to be(false)
      expect(adapter.searchable?(SearchkickSearchPost, 'by_title')).to be(true)
    end

    it "keeps what the model's search_results scope keeps" do
      PgSearchGuardedPost.create!(title: 'milk')
      PgSearchGuardedPost.create!(title: 'stale milk')

      expect(adapter.scope(PgSearchGuardedPost.all, Lighthouse::Search::Query.new(PgSearchGuardedPost, 'milk')).map(&:title)).to eq(['milk'])
    end

    it 'applies the scope the index names to the relation it is given' do
      PgSearchPost.create!(title: 'milk', author_id: 1)
      PgSearchPost.create!(title: 'milk', author_id: 2)
      query = Lighthouse::Search::Query.new(PgSearchPost, 'milk')

      expect(adapter.scope(PgSearchPost.where(author_id: 2), query).map(&:author_id)).to eq([2])
      expect(adapter.scope(PgSearchPost.all, Lighthouse::Search::Query.new(PgSearchPost, 'milk', 'by_title')).count).to eq(2)
    end
  end

  describe Lighthouse::Search::Auto do
    let(:declining) { FakeSearch::Engine.new([]) }
    let(:accepting) { FakeSearch::Engine.new([SearchPost]) }

    it 'picks the first adapter that searches the model' do
      auto = described_class.new([declining, accepting])

      expect(auto.adapter_for(SearchPost, 'idx')).to equal(accepting)
      expect(auto.searchable?(SearchPost)).to be(true)
    end

    it 'finds none' do
      expect(described_class.new([declining]).adapter_for(SearchPost)).to be_nil
    end

    it 'picks pg_search for a model with both gems when within: names one of its pg_search scopes' do
      stub_const('Searchkick', Module.new)
      stub_const('PgSearch::Model', FakeSearch::PgSearchModel)
      auto = described_class.new

      expect(auto.adapter_for(BothSearchPost, 'by_title')).to be_a(Lighthouse::Search::PgSearch)
      expect(auto.adapter_for(BothSearchPost)).to be_a(Lighthouse::Search::Searchkick)
      expect(auto.adapter_for(BothSearchPost, 'an_index')).to be_a(Lighthouse::Search::Searchkick)
      expect(auto.adapter_for(PgSearchPost, 'an_index')).to be_nil
    end

    it 'prefers Searchkick to pg_search by default' do
      stub_const('Searchkick', Module.new)
      stub_const('PgSearch::Model', FakeSearch::PgSearchModel)

      expect(described_class.new.adapter_for(SearchkickPost)).to be_a(Lighthouse::Search::Searchkick)
      expect(described_class.new.adapter_for(PgSearchPost)).to be_a(Lighthouse::Search::PgSearch)
    end
  end

  describe '@trashed in a search' do
    it 'goes to the query of a model with soft deletes' do
      engine = FakeSearch::Engine.new([SearchSoftPost])
      Lighthouse::Config.search = engine
      schema = build_schema(<<~GRAPHQL)
        type SearchSoftPost { id: Int! }
        type Query { posts(search: String @search, trashed: Trashed @trashed): [SearchSoftPost!]! @all }
      GRAPHQL

      expect(schema.execute('{ posts(search: "x", trashed: ONLY) { id } }').to_h['errors']).to be_nil
      expect(engine.query.trashed).to eq(:only)
    end

    it 'refuses a model without soft deletes' do
      Lighthouse::Config.search = FakeSearch::Engine.new([Widget])
      schema = build_schema('type Widget { id: Int! } type Query { widgets(search: String @search, trashed: Trashed @trashed): [Widget!]! @all }')

      result = schema.execute('{ widgets(search: "x", trashed: ONLY) { id } }').to_h

      expect(result['errors'].first['message']).to include('Widget does not support soft deletes')
    end
  end
end
