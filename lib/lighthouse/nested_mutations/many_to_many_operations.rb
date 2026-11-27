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
        records = find_all!(model, operation.plain, within: pivot.related)
        pivot.detach(operation.plain)
        records.each(&:destroy)
      else link_pivot(pivot, model, name, operation)
      end
    end
    pivot.reset
  end

  # The operations that only add or remove join records. What they attach must
  # exist and be one the query may see; a disconnect only detaches related ones.
  def link_pivot(pivot, model, name, operation)
    case name
    when 'sync' then pivot.sync(attachable(model, operation), detaching: true)
    when 'syncWithoutDetaching' then pivot.sync(attachable(model, operation), detaching: false)
    when 'connect' then attachable(model, operation).each { |id, values| pivot.attach(id, values) }
    when 'disconnect' then pivot.detach(operation.plain)
    end
  end

  def attachable(model, operation)
    pairs(operation).tap { |found| find_all!(model, found.map(&:first)) }
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
