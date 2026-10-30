# frozen_string_literal: true

# The models of the search safety spec (spec/lighthouse/search_safety_spec.rb), on
# the search_posts table, each searched by a fake Searchkick whose index is the
# database: a search's hits are the rows (all of them, whatever the model's
# scopes) whose title holds the term, narrowed by the engine's `where:`. So what
# a search may answer and count is known from the database alone. Or the index
# lags the database (FakeSearch::Indexed.stale): it holds the rows as they were
# (safety_stale_index), before the database changed some.

# The rows as an index that lags the database holds them.
ActiveRecord::Schema.define do
  create_table :safety_stale_index, force: true do |t|
    t.string :title
    t.string :body
    t.integer :author_id
    t.datetime :deleted_at
    t.datetime :discarded_at
  end
end

class SafetyStaleRow < ApplicationRecord
  self.table_name = 'safety_stale_index'
end

# What a request runs as: the tenant a default scope reads.
module SafetyCurrent
  def self.tenant = Thread.current[:safety_tenant]

  def self.as(tenant)
    previous = Thread.current[:safety_tenant]
    Thread.current[:safety_tenant] = tenant
    yield
  ensure
    Thread.current[:safety_tenant] = previous
  end
end

module FakeSearch
  # Searchkick's response: its hits (`_index`, `_id`), and the records that loaded, with them.
  IndexResponse = Struct.new(:hits, :records, :total_count) do
    def to_a = records

    def with_hit
      loaded = records.index_by { |record| record.id.to_s }
      hits.filter_map { |hit| (record = loaded[hit['_id']]) && [record, hit] }
    end
  end

  # A model's searchkick_search over an index that is the database, or lags it.
  module Indexed
    # A hit Searchkick answers without loading it (`load: false`), as its HashWrapper.
    Hit = Struct.new(:id, :title)

    class << self
      # Does the index lag the database (safety_stale_index)?
      attr_accessor :stale

      def as(stale)
        previous = self.stale
        self.stale = stale
        yield
      ensure
        self.stale = previous
      end

      # The block, `grow` running once after its first search: what the index and
      # the database gain between two searches of a request.
      def growing(grow)
        @grow = grow
        yield
      ensure
        @grow = nil
      end

      def searched!
        grow = @grow
        @grow = nil
        grow&.call
      end
    end

    def searchkick_index = Struct.new(:name).new(table_name)
    def searchkick_options = {}

    def searchkick_search(term, **options)
      hits = matching(index_rows.order(:id), options[:where] || {})
      hits = hits.where('title LIKE ?', "%#{term}%") unless term.to_s.empty?
      ids = hits.offset(options[:offset]).limit(options[:limit]).pluck(:id)
      response = IndexResponse.new(ids.map { |id| { '_index' => table_name, '_id' => id.to_s } }, loaded(ids, options), hits.count)
      FakeSearch::Indexed.searched!
      response
    end

    # The records of the hits, in their order: loaded through `scope_results:` as
    # Searchkick loads them (through `unscoped` with `unscope: true`), or the
    # index's own rows with `load: false`.
    def loaded(ids, options)
      return index_rows.where(id: ids).map { |row| Hit.new(row.id, row.title) } if options[:load] == false

      loading = searchkick_options[:unscope] ? unscoped : self # Searchkick's results_query
      records = options[:scope_results] ? options[:scope_results].call(loading) : loading
      records.where(id: ids).sort_by { |record| ids.index(record.id) }
    end

    # The rows the index holds: the database's, or as they were.
    def index_rows = FakeSearch::Indexed.stale ? SafetyStaleRow.all : unscoped

    # The rows the engine's `where:` keeps: `_and`, `{ not: value }`, a list, a value.
    def matching(hits, where)
      where.reduce(hits) do |narrowed, (key, value)|
        if key.to_sym == :_and then value.reduce(narrowed) { |acc, condition| matching(acc, condition) }
        elsif value.is_a?(Hash) then narrowed.where.not(key => value[:not])
        else narrowed.where(key => value)
        end
      end
    end

    def self.extended(model)
      model.define_method(:search_data) { attributes.except('id') }
    end
  end
end

# No scope: the index holds what the table holds.
class SafetyPlainPost < ApplicationRecord
  self.table_name = 'search_posts'
  extend FakeSearch::Indexed

  # Who wrote it (@whereAuth): a post stands in for a user, by id.
  belongs_to :author, class_name: 'SafetyPlainPost', optional: true
  has_many :written, class_name: 'SafetyPlainPost', foreign_key: :author_id, inverse_of: :author, dependent: nil

  scope :visible, -> { where.not(body: 'invisible').or(where(body: nil)) }
end

# A tenant's default scope, and the engine's condition for it.
class SafetyTenantPost < SafetyPlainPost
  default_scope { where(author_id: SafetyCurrent.tenant) }

  def self.search_where = { author_id: SafetyCurrent.tenant }
end

# The same scope without an engine condition: the schema must not build.
class SafetyTenantUnfilteredPost < SafetyPlainPost
  default_scope { where(author_id: SafetyCurrent.tenant) }
end

# A tenant's scope only inside a request: built outside one, it narrows nothing.
class SafetyConditionalTenantPost < SafetyPlainPost
  default_scope { where(author_id: SafetyCurrent.tenant) if SafetyCurrent.tenant }
end

# Soft deletes on deleted_at under a default scope, which Lighthouse filters the engine on itself.
class SafetySoftPost < SafetyPlainPost
  default_scope { where(deleted_at: nil) }

  def self.search_where = {}
end

# The same, loaded the way Searchkick's `unscope: true` loads: through `unscoped`.
class SafetyUnscopedSoftPost < SafetySoftPost
  def self.searchkick_options = { unscope: true }
end

# What a search may return, in the database and in the engine alike.
class SafetyGuardedPost < SafetyPlainPost
  scope :search_results, -> { where.not(body: 'hidden') }

  def self.search_where = { body: { not: 'hidden' } }
end
