# frozen_string_literal: true

# What a search holds, as Laravel Scout's builder does: the model, the term and
# what narrows it. The directives of the other arguments write to it
# (Contracts::SearchBuilder), and the adapter runs it (Search::Searchkick#page).
# Directives never know which engine is behind it.
#
# A search of several models together (a union's or an interface's: Search::Together) has
# `models` and no `model`; `for(model)` is the same search of one of them.
class Lighthouse::Search::Query
  # The model searched, the `@search` argument's value, the `within:` index (nil: the model's own).
  attr_reader :model, :term, :index

  # The models searched together, or nil for a search of one.
  attr_reader :models

  # [[column, value], ...], from @eq (and @builder), in order: all of them hold,
  # the same column twice too (a list of inputs), as the database applies them.
  attr_reader :wheres

  # Adapter-specific options, from @builder on an argument (Searchkick's `fields:`, `boost_by:`, ...).
  attr_reader :options

  # :with, :only or :without, from @trashed; nil: the client did not say.
  attr_accessor :trashed

  def initialize(model, term, index = nil, models: nil)
    @model = model
    @term = term
    @index = index
    @models = models
    @wheres = []
    @options = {}
    @trashed = nil
  end

  # The model's name, or the names of the models searched together, for errors.
  def name = models ? models.map(&:name).join(', ') : model.name

  # The same search of `model` alone: its term, conditions and options.
  def for(model)
    self.class.new(model, term, index).tap do |one|
      wheres.each { |column, value| one.where(column, value) }
      one.options.merge!(options)
      one.trashed = trashed
    end
  end

  # The column equals the value, as Scout's `where`.
  def where(column, value)
    @wheres << [column.to_s, value]
    self
  end
end
