# frozen_string_literal: true

# belongsTo / morphTo operations: they set the foreign keys (and morph type)
# of the record being saved, so they run before it is saved.
module Lighthouse::GraphQL::NestedMutations::BelongsToOperations
  private

  def nest_belongs_to(record, reflection, operations, deferred_deletes)
    association = record.association(reflection.name)
    in_order(reflection, operations).each do |name, operation|
      case name
      when 'create', 'update', 'upsert' then association.writer(write(name, reflection.klass, operation.input, operation))
      when 'connect' then connect_owner(record, reflection, operation.plain)
      when 'disconnect' then association.writer(nil) if operation.truthy?
      when 'delete' then delete_owner(record, reflection, operation, deferred_deletes)
      end
    end
  end

  def connect_owner(record, reflection, value)
    if reflection.polymorphic?
      model = morph_model(value[:type])
      record[reflection.foreign_type] = model.polymorphic_name
      record[reflection.foreign_key] = value[:id]
    else
      record[reflection.foreign_key] = value
    end
  end

  # Unlinks the related record now and destroys it only after the record,
  # no longer pointing at it, is saved (see Executor#save).
  def delete_owner(record, reflection, operation, deferred_deletes)
    return unless operation.truthy?

    related = record.public_send(reflection.name)
    record.association(reflection.name).writer(nil)
    deferred_deletes << related if related
  end

  # The model a morphTo `connect` names: a class name, resolved like any
  # model name, or an enum value such as TASK for Task.
  def morph_model(type)
    [type, type.to_s.downcase.camelize].uniq.each do |name|
      model = Lighthouse::Support::ModelResolver.constantize(name)
      return model if model.is_a?(Class) && model < ::ActiveRecord::Base
    end

    raise ::GraphQL::ExecutionError, "Unknown type #{type} to connect."
  end
end
