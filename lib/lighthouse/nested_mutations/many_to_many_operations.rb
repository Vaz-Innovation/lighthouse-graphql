# frozen_string_literal: true

# belongsToMany / morphToMany operations: they run after the owner is saved
# and change its join records (Lighthouse::GraphQL::NestedMutations::Pivot).
module Lighthouse::GraphQL::NestedMutations::ManyToManyOperations
  private

  def nest_many_to_many(record, reflection, operations)
    model = reflection.klass
    pivot = Lighthouse::GraphQL::NestedMutations::Pivot.new(record, reflection)
    link = Lighthouse::GraphQL::NestedMutations::AttachLink.new(pivot)

    in_order(reflection, operations).each do |name, operation|
      case name
      when 'create', 'update', 'upsert' then write_each(name, model, operation, link)
      when 'delete'
        pivot.detach(operation.plain)
        model.where(model.primary_key => operation.plain).destroy_all
      else link_pivot(pivot, name, operation)
      end
    end
    pivot.reset
  end

  # The operations that only add or remove join records.
  def link_pivot(pivot, name, operation)
    case name
    when 'sync' then pivot.sync(pairs(operation), detaching: true)
    when 'syncWithoutDetaching' then pivot.sync(pairs(operation), detaching: false)
    when 'connect' then pairs(operation).each { |id, values| pivot.attach(id, values) }
    when 'disconnect' then pivot.detach(operation.plain)
    end
  end

  # [[id, pivot values], ...] from a list of IDs or of { id, ...pivot } inputs.
  def pairs(operation)
    Array(operation.plain).map do |item|
      next [item, {}] unless item.is_a?(Hash)

      values = item.transform_keys(&:to_s)
      [values.delete('id'), values]
    end
  end
end
