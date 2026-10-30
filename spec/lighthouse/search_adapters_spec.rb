# frozen_string_literal: true

require 'spec_helper'

# The adapters of the two gems, without the gems: what each asks of them and how it detects its model.
# example/ runs them against OpenSearch and PostgreSQL.
RSpec.describe 'search adapters' do
  describe Lighthouse::Search::Searchkick do
    subject(:adapter) { described_class.new }

    let(:query) { Lighthouse::Search::Query.new(SearchkickPost, 'milk') }

    before do
      stub_const('Searchkick', Module.new)
      SearchkickPost.searches = []
      SearchkickPost.indexed = %w[title deleted_at]
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
      expect(SearchkickPost.searches).to eq(
        [['milk', { where: { author_id: 3 }, fields: ['title'], load: true, body_options: { track_total_hits: true }, offset: 20, limit: 10 }]]
      )
    end

    it 'asks for the exact total, which Elasticsearch and OpenSearch 7+ stop counting at 10,000, unless the app says otherwise' do
      adapter.page(query, offset: 0, limit: 1)
      expect(searched.last[:body_options]).to eq(track_total_hits: true)

      query.options[:body_options] = { track_total_hits: 50_000, min_score: 1 }
      adapter.page(query, offset: 0, limit: 1)
      expect(searched.last[:body_options]).to eq(track_total_hits: 50_000, min_score: 1)
    end

    it 'searches the index within: names, and merges the where of a builder' do
      query = Lighthouse::Search::Query.new(SearchkickPost, 'milk', 'other_index')
      query.options[:where] = { published: true }
      query.where('author_id', 3)

      adapter.page(query, offset: 0, limit: 1)

      expect(searched.last).to include(where: { published: true, author_id: 3 }, index_name: 'other_index', offset: 0, limit: 1)
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

      it 'filters on the column the adapter names' do
        SearchkickPost.indexed = %w[archived_at]

        expect(where_of(:only, described_class.new(trashed_column: :archived_at))).to eq(archived_at: { not: nil })
      end

      it 'refuses a model that does not index the column' do
        SearchkickPost.indexed = %w[title]

        expect { where_of(:only) }.to raise_error(GraphQL::ExecutionError, /SearchkickPost.search_data does not index deleted_at/)
      end

      it 'takes the column as indexed when search_data cannot run on a blank record' do
        SearchkickPost.indexed = :raise

        expect(where_of(:only)).to eq(deleted_at: { not: nil })
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
