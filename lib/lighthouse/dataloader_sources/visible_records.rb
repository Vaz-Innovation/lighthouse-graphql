# frozen_string_literal: true

# Which of the records a relationship loaded its type's scope_items keeps
# (TypeAuthorization.visible): one query per model for every record of a
# batch, so scoping a batched relationship does not undo the batch.
class Lighthouse::GraphQL::DataloaderSources::VisibleRecords < GraphQL::Dataloader::Source
  def initialize(type_class, context)
    super()
    @type_class = type_class
    @context = context
  end

  # keys: records; true for each one the scope keeps.
  def fetch(records)
    kept = records.group_by { |record| record.class.base_class }.flat_map do |model, group|
      key = model.primary_key
      scoped = @type_class.scope_items(model.where(key => group.map { |record| record.public_send(key) }), @context)
      unless scoped.respond_to?(:pluck)
        raise Lighthouse::DefinitionError, "#{@type_class}.scope_items must answer a relation for Lighthouse to query (got #{scoped.class})"
      end

      scoped.pluck(key).map { |id| [model, id] }
    end.to_set
    records.map { |record| kept.include?([record.class.base_class, record.public_send(record.class.primary_key)]) }
  end
end
