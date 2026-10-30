# frozen_string_literal: true

require 'paranoia'
require 'discard'
require_relative 'pg_search/model'

# The models and engines of the @search specs. The engines are fakes, as PHP
# Lighthouse's own suite fakes Laravel Scout's (tests/TestsScoutEngine): the
# real ones run in example/ against OpenSearch and PostgreSQL.
ActiveRecord::Schema.define do
  create_table :search_posts, force: true do |t|
    t.string :title
    t.string :body
    t.integer :author_id
    t.datetime :deleted_at
    t.datetime :discarded_at
  end
end

class SearchPost < ApplicationRecord
  # Posts whose author_id is this post's id: a parent and its related ones.
  has_many :related, class_name: 'SearchPost', foreign_key: :author_id, primary_key: :id, inverse_of: false, dependent: nil

  has_many :paged, class_name: 'SearchPost', foreign_key: :author_id, primary_key: :id, inverse_of: false, dependent: nil

  scope :roots, -> { where(author_id: nil) }
  scope :with_author, -> { where.not(author_id: nil) }
end

class Builders::SearchSpecOnlyBodied
  def self.call(relation, _args, _context) = relation.where.not(body: nil)
end

# A soft-deleting one: a `deleted_at` column is all @trashed needs.
class SearchSoftPost < ApplicationRecord
  self.table_name = 'search_posts'
end

module FakeSearch
  # An engine outside the database, like Searchkick: answers with the records it was given,
  # and keeps the queries it was asked.
  class Engine
    attr_reader :requests

    def initialize(models, records = [])
      @models = models
      @records = records
      @requests = []
    end

    def searchable?(model, _index = nil) = @models.include?(model)
    def relational? = false

    def page(query, offset:, limit:)
      @requests << { query: query, offset: offset, limit: limit }
      [@records.drop(offset).first(limit), @records.size]
    end

    def query = @requests.last[:query]
  end

  # A search in the database, like pg_search: a scope on the relation.
  class Relational
    attr_reader :queries

    def initialize(models)
      @models = models
      @queries = []
    end

    def searchable?(model, _index = nil) = @models.include?(model)
    def relational? = true

    def scope(relation, query)
      @queries << query
      relation.where('title LIKE ?', "%#{query.term}%")
    end
  end
end

module FakeSearch
  Response = Struct.new(:records, :total_count) do
    def to_a = records
  end
end

# A model that calls `searchkick`: it answers what Searchkick's model methods do, and keeps the searches.
class SearchkickPost < ApplicationRecord
  self.table_name = 'search_posts'

  class << self
    attr_accessor :searches, :indexed

    def searchkick_index = nil
    def searchkick_options = {}

    def searchkick_search(term, **options)
      searches << [term, options]
      FakeSearch::Response.new([new(title: 'a'), new(title: 'b')], 7)
    end
  end

  def search_data
    raise 'needs a record' if self.class.indexed == :raise

    self.class.indexed.index_with { |column| self[column] }
  end
end

# A model that includes PgSearch::Model, with the `search` scope pg_search_scope would define.
class PgSearchPost < ApplicationRecord
  self.table_name = 'search_posts'
  include FakeSearch::PgSearchModel

  pg_search_scope :search, ->(term) { where('title LIKE ?', "%#{term}%") }
  pg_search_scope :by_title, ->(term) { where(title: term) }

  # The order pg_search 2.4 adds: the rank, then the primary key, two nodes.
  pg_search_scope :ranked24, ->(term) { search(term).order(Arel::Table.new('pg_search_1')[:rank].desc).order(arel_table[:id].asc) }

  # pg_search 2.3's: one SQL literal, with `order_within_rank:` or the primary key after the rank.
  pg_search_scope :ranked23, ->(term) { search(term).order(Arel.sql(%(pg_search_1.rank DESC, "search_posts"."id" ASC))) }
  pg_search_scope :ranked23_within, ->(term) { search(term).order(Arel.sql(%(pg_search_1.rank DESC, search_posts.title DESC))) }
end

# A model's searchkick_search that loads its hits as Searchkick does
# (Searchkick::Results#results_query): through the model and its default scope,
# then `scope_results:`. The index holds every row, trashed ones too, filtered by
# `where:`; a `{ not: nil }` filter keeps the rows with a value in the column.
module FakeSearch::Searchkicked
  attr_accessor :searches

  # The index holds every column.
  def self.extended(model)
    model.define_method(:search_data) { attributes.except('id') }
  end

  def searchkick_index = nil
  def searchkick_options = {}

  def searchkick_search(_term, **options)
    (self.searches ||= []) << options
    hits = filtered(options[:where] || {})
    ids = hits.offset(options[:offset]).limit(options[:limit]).pluck(:id)
    records = options[:scope_results] ? options[:scope_results].call(self) : self
    FakeSearch::Response.new(records.where(id: ids).sort_by { |record| ids.index(record.id) }, hits.count)
  end

  def filtered(wheres)
    wheres.reduce(unscoped.order(:id)) do |hits, (column, value)|
      value.is_a?(Hash) ? hits.where.not(column => value[:not]) : hits.where(column => value)
    end
  end
end

# Searchkick models with soft deletes, whose default scope hides the trashed ones
# (paranoia's, discard's when the model asks for it, and a hand-written one).
class SearchkickParanoidPost < ApplicationRecord
  self.table_name = 'search_posts'
  acts_as_paranoid
  extend FakeSearch::Searchkicked

  # Lighthouse filters the engine on the soft-delete column itself.
  def self.search_where = {}
end

# paranoia with a sentinel: a kept record holds it in deleted_at, not null.
class SearchkickSentinelPost < ApplicationRecord
  self.table_name = 'search_posts'
  acts_as_paranoid sentinel_value: DateTime.new(0)
  extend FakeSearch::Searchkicked

  def self.search_where = {}
end

class SearchkickDiscardPost < ApplicationRecord
  self.table_name = 'search_posts'
  include Discard::Model
  extend FakeSearch::Searchkicked

  default_scope -> { kept }

  def self.search_where = {}
end

class SearchkickHiddenPost < ApplicationRecord
  self.table_name = 'search_posts'
  extend FakeSearch::Searchkicked

  default_scope { where(deleted_at: nil) }

  # Its scope's condition, unless deleted_at is the soft-delete column, which Lighthouse filters on itself.
  def self.search_where = Lighthouse::Support::SoftDeletes.column(self) == 'deleted_at' ? {} : { deleted_at: nil }
end

# One whose `search_results` scope keeps what a search may return, whatever the index holds.
class SearchkickGuardedPost < ApplicationRecord
  self.table_name = 'search_posts'
  extend FakeSearch::Searchkicked

  scope :search_results, -> { where.not(title: 'stale') }

  # The index holds 'stale' (not yet removed): the engine counts it, the load drops it.
  def self.search_where = {}
end

class PgSearchGuardedPost < PgSearchPost
  scope :search_results, -> { where.not('title LIKE ?', 'stale%') }
end

# A model with both gems: Searchkick's index, and pg_search's scopes (`search`, `by_title`).
class BothSearchPost < PgSearchPost
  extend FakeSearch::Searchkicked
end

# A default scope that reads the clock: its SQL differs every time it is built.
class SearchTimedPost < ApplicationRecord
  self.table_name = 'search_posts'

  default_scope { where('deleted_at IS NULL OR deleted_at > ?', Time.current) }
end

# A default order, and a search_results scope that orders too: a search sorts by rank before them.
class PgSearchOrderedPost < PgSearchPost
  default_scope { order(title: :desc) }

  scope :search_results, -> { order(author_id: :desc) }
end

# A model without the `paged` association, and a subclass that has it: what the
# schema's type tells of a parent is not always what a query's records are.
class SearchPlainPost < ApplicationRecord
  self.table_name = 'search_posts'
end

class SearchPlainPostWithPaged < SearchPlainPost
  has_many :paged, class_name: 'SearchPost', foreign_key: :author_id, primary_key: :id, inverse_of: false, dependent: nil
end

# A tenant's default scope: what the index holds of every tenant must not be counted.
class SearchkickTenantPost < ApplicationRecord
  self.table_name = 'search_posts'
  extend FakeSearch::Searchkicked

  default_scope { where(author_id: 1) }
end

# The same, telling the engine its tenant's condition.
class SearchkickTenantFilteredPost < SearchkickTenantPost
  def self.search_where = { author_id: 1 }
end

# A default scope that narrows without a condition: a LIMIT.
class SearchkickLimitedPost < ApplicationRecord
  self.table_name = 'search_posts'
  extend FakeSearch::Searchkicked

  default_scope { limit(1) }
end

# A model with both gems whose `search` is Searchkick's, not a pg_search scope.
class SearchkickSearchPost < PgSearchPost
  extend FakeSearch::Searchkicked

  def self.search(term, **) = searchkick_search(term)
end
