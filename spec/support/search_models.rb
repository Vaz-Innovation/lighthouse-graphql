# frozen_string_literal: true

# The models and engines of the @search specs. The engines are fakes, as PHP
# Lighthouse's own suite fakes Laravel Scout's (tests/TestsScoutEngine): the
# real ones run in example/ against OpenSearch and PostgreSQL.
ActiveRecord::Schema.define do
  create_table :search_posts, force: true do |t|
    t.string :title
    t.string :body
    t.integer :author_id
    t.datetime :deleted_at
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

  # What `include PgSearch::Model` stands for when the gem is not in the bundle.
  module PgSearchModel; end
end

# A model that calls `searchkick`: it answers what Searchkick's model methods do, and keeps the searches.
class SearchkickPost < ApplicationRecord
  self.table_name = 'search_posts'

  class << self
    attr_accessor :searches, :indexed

    def searchkick_index = nil

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

  def self.search(term) = where('title LIKE ?', "%#{term}%")
  def self.by_title(term) = where(title: term)
end
