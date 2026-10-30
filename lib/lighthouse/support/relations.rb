# frozen_string_literal: true

# What tells two relations of a model apart by the records they select, for
# the checks a search outside the database needs: is a relation the model's
# own (Search::Enhancer), has the model a default scope (Search::Searchkick)?
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

  # Has the model a default scope? Told from its declaration, never from what it
  # selects now: a scope that reads the request (`where(tenant_id:
  # Current.tenant_id) if Current.tenant_id`) narrows nothing outside one, and
  # everything within. Any default scope counts, an order alone too.
  def default_scope?(model) = model.respond_to?(:default_scopes) && model.default_scopes.any?

  # `none`: a null relation (Rails 7.1+ answers null_relation?).
  def null?(relation)
    return relation.null_relation? if relation.respond_to?(:null_relation?)

    !!(defined?(::ActiveRecord::NullRelation) && relation.is_a?(::ActiveRecord::NullRelation))
  end
end
