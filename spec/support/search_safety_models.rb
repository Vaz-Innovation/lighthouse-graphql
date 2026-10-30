# frozen_string_literal: true

# The models of the search safety spec (spec/lighthouse/search_safety_spec.rb), on
# the search_posts table, each searched by a fake Searchkick whose index is the
# database: a search's hits are the rows (all of them, whatever the model's
# scopes) whose title holds the term, narrowed by the engine's `where:`. So what
# a search may answer and count is known from the database alone.

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

  # A model's searchkick_search over an index that is the database.
  module Indexed
    def searchkick_index = Struct.new(:name).new(table_name)
    def searchkick_options = {}

    def searchkick_search(term, **options)
      hits = matching(unscoped.order(:id), options[:where] || {})
      hits = hits.where('title LIKE ?', "%#{term}%") unless term.to_s.empty?
      ids = hits.offset(options[:offset]).limit(options[:limit]).pluck(:id)
      records = options[:scope_results] ? options[:scope_results].call(self) : self
      loaded = records.where(id: ids).sort_by { |record| ids.index(record.id) }
      IndexResponse.new(ids.map { |id| { '_index' => table_name, '_id' => id.to_s } }, loaded, hits.count)
    end

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

# Soft deletes on deleted_at under a default scope, and the engine's condition for it.
class SafetySoftPost < SafetyPlainPost
  default_scope { where(deleted_at: nil) }

  def self.search_where = { deleted_at: nil }
end

# What a search may return, in the database and in the engine alike.
class SafetyGuardedPost < SafetyPlainPost
  scope :search_results, -> { where.not(body: 'hidden') }

  def self.search_where = { body: { not: 'hidden' } }
end
