# frozen_string_literal: true

# hasOne / morphOne and hasMany / morphMany operations: their records point
# back at the saved owner, so they run after it is saved.
module Lighthouse::GraphQL::NestedMutations::HasOperations
  BOOLEANS = [true, false].freeze

  private

  def nest_has_one(record, reflection, operations)
    model = reflection.klass
    link = Lighthouse::GraphQL::NestedMutations::HasLink.new(record, reflection)
    existing = -> { record.association(reflection.name).scope.first }

    in_order(reflection, operations).each do |name, operation|
      case name
      when 'create'
        refuse_second_child!(record, model, existing.call)
        create(model, operation.input, link: link)
      # An upsert that identifies no record updates the current one, if any.
      when 'update', 'upsert' then write(name, model, operation.input, operation, link: link) { existing.call }
      when 'delete' then delete_child(model, operation, existing)
      end
    end
  end

  def refuse_second_child!(record, model, existing)
    return unless existing

    raise ::GraphQL::ExecutionError,
          "Cannot create a related model: a #{model.name.demodulize} already exists for this " \
          "#{record.class.name.demodulize}. Use upsert to modify the existing model."
  end

  # An ID, or — as for any single relation — a Boolean meaning "the current one".
  def delete_child(model, operation, existing)
    if BOOLEANS.include?(operation.value)
      existing.call&.destroy! if operation.value
    else
      model.where(model.primary_key => operation.plain).destroy_all
    end
  end

  def nest_has_many(record, reflection, operations)
    model = reflection.klass
    link = Lighthouse::GraphQL::NestedMutations::HasLink.new(record, reflection)

    in_order(reflection, operations).each do |name, operation|
      case name
      when 'create', 'update', 'upsert' then write_each(name, model, operation, link)
      when 'connect' then relink(model, operation) { |child| link.before_save(child) }
      when 'disconnect' then relink(model, operation) { |child| child[reflection.foreign_key] = nil }
      when 'delete' then model.where(model.primary_key => operation.plain).destroy_all
      end
    end
  end

  # Re-points (or detaches) the existing children the operation names, and
  # saves each through its validations, errors keyed by the operation's path.
  def relink(model, operation)
    model.where(model.primary_key => operation.plain).each do |child|
      yield child
      persist!(child, Hash.new { operation.path.join('.') })
    end
  end
end
