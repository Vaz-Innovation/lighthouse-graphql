# frozen_string_literal: true

# Saves records from nested input: create, update and upsert each save one
# record, running the operations its input carries on its associations.
#
# Every existing record an operation names is looked up among the ones the
# query may see, its type's scope_items (TypeAuthorization): one it hides is
# as missing as one that does not exist. An update, upsert, delete or
# disconnect on a has-one, has-many or many-to-many association (whose `link`
# knows the parent's related records) only reaches records related to the
# parent; connect, sync and a belongs-to's operations bind records not related yet.
class Lighthouse::GraphQL::NestedMutations::Executor
  include Lighthouse::GraphQL::NestedMutations::BelongsToOperations
  include Lighthouse::GraphQL::NestedMutations::HasOperations
  include Lighthouse::GraphQL::NestedMutations::ManyToManyOperations

  NOT_RELATED = 'Cannot modify a model that is not related to the given parent: %s.'

  # `context`: the query's, for the scope_items of the records it looks up.
  def initialize(field_name, context = nil)
    @field_name = field_name
    @context = context
  end

  def create(model, input, link: nil)
    save(model.new, partition(model, input), link)
  end

  def update(model, input, link: nil)
    part = partition(model, input)
    key, id = part.take_key(model)
    raise ::GraphQL::ExecutionError, Lighthouse::GraphQL::NestedMutations::MISSING_PRIMARY_KEY if key.nil? || id.nil?

    part.attributes.delete(key)
    save(find!(model, id, within: link&.related), part, link)
  end

  # The record identified by `identifying` columns, else by primary key,
  # else `fallback`, else a new one — created with the given id, if any. An
  # id of a record it may not reach is an error, not a new record.
  def upsert(model, input, link: nil, identifying: nil, fallback: nil)
    part = partition(model, input)
    within = link&.related
    record = identifying.nil? ? nil : find_identified(model, part, identifying, within)
    record ||= find_by_given_key(model, part, within)
    save(record || fallback || model.new, part, link)
  end

  # The record `id` names among the ones the query may see (and, `within:` a
  # parent's related records, among those).
  def find!(model, id, within: nil)
    reachable(model, within).find_by(model.primary_key => id) || raise(::GraphQL::ExecutionError, missing(model, [id], within))
  end

  # Every record `ids` names, reachable as find! reaches one; checked all
  # before any changes, the error naming every one that is not.
  def find_all!(model, ids, within: nil)
    ids = Array(ids)
    found = reachable(model, within).where(model.primary_key => ids).to_a
    absent = ids.map(&:to_s) - found.map { |record| record[model.primary_key].to_s }
    raise ::GraphQL::ExecutionError, missing(model, absent, within) unless absent.empty?

    found
  end

  # The records of `model` (or of the parent's related ones) the query may see.
  def reachable(model, within = nil)
    Lighthouse::GraphQL::TypeAuthorization.scope_model((within || model).all, @context)
  end

  # Assign, run the operations that set this record's foreign keys, save
  # once, then run the operations on associations pointing back at it.
  def save(record, part, link = nil)
    record.assign_attributes(part.attributes)
    deferred_deletes = []
    before, after = part.operations.partition { |reflection, _| owner_side?(reflection) }

    before.each { |reflection, operations| nest_belongs_to(record, reflection, operations, deferred_deletes) }
    link&.before_save(record)
    persist!(record, part.paths)
    link&.after_save(record)
    deferred_deletes.each(&:destroy!)
    after.each { |reflection, operations| dependents(record, reflection, operations) }

    part.operations.each_key { |reflection| record.association(reflection.name).reset }
    record
  end

  def persist!(record, paths)
    return record if record.save

    messages = {}
    record.errors.each do |error|
      path = error.attribute == :base ? base_path(paths) : paths[error.attribute.to_s]
      (messages[path] ||= []) << error.full_message
    end
    raise Lighthouse::ValidationError.new(@field_name, messages)
  end

  private

  def partition(model, input)
    Lighthouse::GraphQL::NestedMutations::Partitioner.new(model, input).call
  end

  def base_path(paths)
    prefix = paths.default_proc.call({}, '').delete_suffix('.')
    prefix.empty? ? @field_name : prefix
  end

  def missing(model, ids, within)
    return format(NOT_RELATED, ids.join(', ')) if within

    "Couldn't find #{model.name} with '#{model.primary_key}'=#{ids.join(', ')}"
  end

  def find_identified(model, part, columns, within)
    raise Lighthouse::DefinitionError, "@upsert's identifyingColumns must not be empty." if columns.empty?

    values = columns.to_h { |column| [column.to_s, part.attributes[column.to_s]] }
    raise ::GraphQL::ExecutionError, Lighthouse::GraphQL::NestedMutations::MISSING_IDENTIFYING_COLUMNS if values.values.any?(&:nil?)

    reachable(model, within).find_by(values)
  end

  # The record the input's primary key (`id`, or the model's own) names. A
  # blank key is dropped so the database assigns one; a key no record has
  # becomes the new record's primary key. A key of a record the query may not
  # reach (hidden, or not related to the parent) is an error.
  def find_by_given_key(model, part, within)
    key, id = part.take_key(model)
    return nil if key.nil?

    if id.nil? || id.to_s.empty?
      part.attributes.delete(key)
      return nil
    end

    record = reachable(model, within).find_by(model.primary_key => id)
    return record if record

    refuse_existing!(model, id, within)
    part.attributes[model.primary_key] = part.attributes.delete(key) if key != model.primary_key
    nil
  end

  # An upsert's key of a record that exists but is out of reach is no new record's.
  def refuse_existing!(model, id, within)
    raise ::GraphQL::ExecutionError, missing(model, [id], within) if model.exists?(model.primary_key => id)
  end

  # ----------------------------------------------------------------------
  # Operations (the relation kinds' own are in the *Operations modules)

  def kind(reflection)
    Lighthouse::GraphQL::NestedMutations.kind(reflection)
  end

  def owner_side?(reflection)
    %i[belongs_to morph_to].include?(kind(reflection))
  end

  def dependents(record, reflection, operations)
    case kind(reflection)
    when :has_one then nest_has_one(record, reflection, operations)
    when :has_many then nest_has_many(record, reflection, operations)
    when :many_to_many then nest_many_to_many(record, reflection, operations)
    end
  end

  # PHP Lighthouse's fixed order, whatever order the client wrote them in.
  def in_order(reflection, operations)
    Lighthouse::GraphQL::NestedMutations::OPERATIONS.fetch(kind(reflection)).filter_map do |name|
      [name, operations[name]] if operations[name]
    end
  end

  # The create, update or upsert operation `name` on one input; an upsert
  # that identifies no record falls back to the one the block returns.
  def write(name, model, input, operation, link: nil)
    case name
    when 'create' then create(model, input, link: link)
    when 'update' then update(model, input, link: link)
    when 'upsert'
      fallback = yield if block_given?
      # rubocop:disable-next Rails/SkipsModelValidations -- Executor#upsert, not ActiveRecord's: it saves through validations.
      upsert(model, input, link: link, identifying: operation.identifying, fallback: fallback)
    end
  end

  def write_each(name, model, operation, link)
    operation.inputs.each { |input| write(name, model, input, operation, link: link) }
  end
end
