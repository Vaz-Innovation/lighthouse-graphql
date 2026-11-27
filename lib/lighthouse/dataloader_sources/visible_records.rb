# frozen_string_literal: true

# Which of the records a field loaded their type's scope_items keeps
# (TypeAuthorization.visible): one query per model for every record of a
# batch, so scoping a batched relationship does not undo the batch.
class Lighthouse::GraphQL::DataloaderSources::VisibleRecords < GraphQL::Dataloader::Source
  # The records a field loaded (one, a list, or nil), less the ones the
  # scope_items of the type each resolves as leaves out: the field's object
  # type, or, through an interface or a union, the type of each record's model.
  def self.filter(value, field_def, context)
    return value unless context && value && Lighthouse::GraphQL::TypeAuthorization.index(context).any?

    records = Array.wrap(value)
    hidden = hidden_records(records, field_def, context)
    return value if hidden.empty?

    kept = records.reject { |record| hidden.key?(record) }
    value.respond_to?(:to_ary) ? kept : kept.first
  end

  # { record => true } for each record its type's scope_items leaves out.
  def self.hidden_records(records, field_def, context)
    scoped_groups(records, field_def, context).each_with_object({}.compare_by_identity) do |(klass, group), hidden|
      group.zip(shown(klass, group, context)).each { |record, kept| hidden[record] = true unless kept }
    end
  end

  # { type class => its records } for the ones a scope_items applies to.
  def self.scoped_groups(records, field_def, context)
    authorization = Lighthouse::GraphQL::TypeAuthorization
    kind, name = authorization.records_of(field_def, context)
    case kind
    when :object
      klass = authorization.object_scoping_class(name, context)
      klass ? { klass => records } : {}
    when :abstract
      records.group_by { |record| authorization.model_scoping_class(field_def, record.class, context) }.except(nil)
    else {}
    end
  end

  # Whether each record is one `klass`'s scope_items keeps: batched with the
  # other parents' through the Dataloader, at once without one.
  def self.shown(klass, records, context)
    dataloader = Lighthouse::Support::Batching.dataloader(context)
    return new(klass, context).fetch(records) unless dataloader

    dataloader.with(self, klass, context).load_all(records)
  end

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
