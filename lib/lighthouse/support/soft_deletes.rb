# frozen_string_literal: true

# Soft deletes behind one seam, for @softDeletes / @trashed, @restore,
# @forceDelete and @withoutGlobalScopes. Rails has no built-in soft deletes, so
# the model's strategy is detected, in this order:
#
# - paranoia (`acts_as_paranoid`): a default scope hides trashed records.
# - discard (`include Discard::Model`): nothing is hidden unless the model
#   adds `default_scope -> { kept }`.
# - a plain `deleted_at` column (Column), with no gem.
#
# `Config.soft_deletes` replaces the detection with an adapter of the app's
# own: any object answering `soft_deletes?(model)`, `only_trashed(relation)`,
# `with_trashed(relation)`, `without_trashed(relation)`, `restore(record)` and
# `force_delete(record)` (the last two answering whether they succeeded), and
# optionally `column(model)` and `kept_value(model)`: the column that marks the
# trashed records and its value for the others, which a search engine filters on
# (Search::Searchkick). `Column.new(:archived_at)` is a ready-made one for another
# column name.
module Lighthouse::Support::SoftDeletes
  module_function

  # The adapter in use: Config.soft_deletes, else the detecting one.
  def adapter
    Lighthouse::Config.soft_deletes || (@default ||= Lighthouse::Support::SoftDeletes::Auto.new)
  end

  def supported?(model)
    adapter.soft_deletes?(model)
  end

  # A client-facing error: the schema asks for soft deletes on a model without them.
  def require_support!(model)
    return if supported?(model)

    raise ::GraphQL::ExecutionError,
          "Model #{model.name} does not support soft deletes (no paranoia, discard or deleted_at column; see Config.soft_deletes)."
  end

  def only_trashed(relation)
    require_support!(relation.klass)
    adapter.only_trashed(relation)
  end

  def with_trashed(relation)
    require_support!(relation.klass)
    adapter.with_trashed(relation)
  end

  def without_trashed(relation)
    require_support!(relation.klass)
    adapter.without_trashed(relation)
  end

  TRASHED = { 'ONLY' => :only, 'WITH' => :with, 'WITHOUT' => :without }.freeze

  # :only, :with or :without, for a `Trashed` enum value (ONLY, WITH or WITHOUT).
  def trashed(value)
    TRASHED.fetch(value.to_s.upcase) do
      raise ::GraphQL::ExecutionError, "Unknown trashed value #{value.inspect}, expected ONLY, WITH or WITHOUT."
    end
  end

  # The relation for a `Trashed` enum value: ONLY, WITH or WITHOUT.
  def filter(relation, value)
    case trashed(value)
    when :only then only_trashed(relation)
    when :with then with_trashed(relation)
    else without_trashed(relation)
    end
  end

  # The column that marks the model's trashed records, as the adapter tells it
  # (`column(model)`), for a search engine to filter on; nil when it does not.
  def column(model)
    adapter.respond_to?(:column) ? adapter.column(model)&.to_s : nil
  end

  # What that column holds for the records that are not trashed: nil, or
  # paranoia's sentinel value (`kept_value(model)`).
  def kept_value(model)
    adapter.respond_to?(:kept_value) ? adapter.kept_value(model) : nil
  end

  def restore(record)
    require_support!(record.class)
    adapter.restore(record)
  end

  def force_delete(record)
    require_support!(record.class)
    adapter.force_delete(record)
  end

  # paranoia: `with_deleted` / `only_deleted` / `#restore` / `#really_destroy!`.
  class Paranoia
    def soft_deletes?(model)
      return false unless defined?(::Paranoia)

      model.respond_to?(:paranoid?) && model.paranoid?
    end

    def only_trashed(relation) = relation.only_deleted
    def with_trashed(relation) = relation.with_deleted

    def without_trashed(relation)
      model = relation.klass
      relation.with_deleted.where(model.paranoia_column => model.paranoia_sentinel_value)
    end

    def restore(record) = record.restore

    def force_delete(record) = record.really_destroy!

    def column(model) = model.paranoia_column
    def kept_value(model) = model.paranoia_sentinel_value
  end

  # discard: `kept` / `discarded` scopes, `#undiscard`; `#destroy` really deletes.
  class Discard
    def soft_deletes?(model)
      return false unless defined?(::Discard::Model)

      model.include?(::Discard::Model)
    end

    def only_trashed(relation) = with_trashed(relation).discarded
    def with_trashed(relation) = relation.unscope(where: relation.klass.discard_column)
    def without_trashed(relation) = with_trashed(relation).kept

    def restore(record) = record.undiscard

    def force_delete(record) = record.destroy

    def column(model) = model.discard_column
    def kept_value(_model) = nil
  end

  # A nullable timestamp column (`deleted_at` by default) and no gem. It marks
  # trashed records with a value and may or may not be hidden by a default scope:
  # every filter unscopes the column first, so both work. Restoring sets it to
  # null (skipping callbacks and validations); force deleting is `#destroy`.
  class Column
    DEFAULT_COLUMN = 'deleted_at'

    def initialize(column = DEFAULT_COLUMN)
      @column = column.to_s
    end

    def soft_deletes?(model)
      model.respond_to?(:column_names) && model.table_exists? && model.column_names.include?(@column)
    rescue ::ActiveRecord::ActiveRecordError
      false
    end

    def only_trashed(relation) = with_trashed(relation).where.not(@column => nil)
    def with_trashed(relation) = relation.unscope(where: @column)
    def without_trashed(relation) = with_trashed(relation).where(@column => nil)

    def restore(record)
      record.update_columns(@column => nil) # rubocop:disable Rails/SkipsModelValidations -- a trashed record may no longer validate.
    end

    def force_delete(record) = record.destroy

    def column(_model) = @column
    def kept_value(_model) = nil
  end

  # The default adapter: asks each strategy, in order, whether the model uses it.
  class Auto
    def initialize(strategies = nil)
      @strategies = strategies || [Paranoia.new, Discard.new, Column.new]
    end

    def soft_deletes?(model)
      !strategy(model).nil?
    end

    def only_trashed(relation) = strategy!(relation.klass).only_trashed(relation)
    def with_trashed(relation) = strategy!(relation.klass).with_trashed(relation)
    def without_trashed(relation) = strategy!(relation.klass).without_trashed(relation)
    def restore(record) = strategy!(record.class).restore(record)
    def force_delete(record) = strategy!(record.class).force_delete(record)
    def column(model) = strategy(model)&.column(model)
    def kept_value(model) = strategy(model)&.kept_value(model)

    private

    def strategy(model)
      @strategies.find { |strategy| strategy.soft_deletes?(model) }
    end

    def strategy!(model)
      strategy(model) || raise(::GraphQL::ExecutionError, "Model #{model.name} does not support soft deletes.")
    end
  end
end
