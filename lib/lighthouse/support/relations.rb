# frozen_string_literal: true

# What tells two relations of a model apart by the records they select, for
# the checks a search outside the database needs: is a relation the model's
# own (Search::Enhancer), does a default scope narrow the model (Search::Searchkick)?
module Lighthouse::Support::Relations
  module_function

  # The parts of a relation that decide which records it selects. Order, select
  # and preloading do not.
  SELECTING = %i[where_clause having_clause from_clause joins_values left_outer_joins_values group_values limit_value offset_value].freeze

  # Does `relation` select what `other` does? Each part equal, conditions and their
  # values included; a null relation (`none`) selects nothing.
  def same_records?(relation, other)
    null?(relation) == null?(other) && SELECTING.all? { |part| relation.public_send(part) == other.public_send(part) }
  end

  # Does the model's default scope narrow its records? When it cannot be told
  # (it raises outside a request), it is taken to.
  def narrowing_default_scope?(model)
    !same_records?(model.all, model.unscoped)
  rescue StandardError
    true
  end

  # `none`: a null relation (Rails 7.1+ answers null_relation?).
  def null?(relation)
    return relation.null_relation? if relation.respond_to?(:null_relation?)

    !!(defined?(::ActiveRecord::NullRelation) && relation.is_a?(::ActiveRecord::NullRelation))
  end
end
