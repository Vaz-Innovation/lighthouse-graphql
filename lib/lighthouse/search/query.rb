# frozen_string_literal: true

# What a search holds, as Laravel Scout's builder does: the model, the term and
# what narrows it. The directives of the other arguments write to it
# (Contracts::SearchBuilder), and the adapter runs it (Search::Searchkick#page).
# Directives never know which engine is behind it.
class Lighthouse::Search::Query
  # The model searched, the `@search` argument's value, the `within:` index (nil: the model's own).
  attr_reader :model, :term, :index

  # { column => value }, from @eq (and @builder).
  attr_reader :wheres

  # Adapter-specific options, from @builder on an argument (Searchkick's `fields:`, `boost_by:`, ...).
  attr_reader :options

  # :with, :only or :without, from @trashed; nil: the client did not say.
  attr_accessor :trashed

  def initialize(model, term, index = nil)
    @model = model
    @term = term
    @index = index
    @wheres = {}
    @options = {}
    @trashed = nil
  end

  # The column equals the value, as Scout's `where`.
  def where(column, value)
    @wheres[column.to_s] = value
    self
  end
end
