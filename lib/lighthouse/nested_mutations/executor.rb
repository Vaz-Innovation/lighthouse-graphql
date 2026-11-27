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

  # The records a list of update or upsert inputs names, looked up in one
  # query (write_each), by key; `taken`: the keys of the ones that exist but
  # are out of reach, which an upsert may not take for a new record.
  Prefetched = Struct.new(:records, :taken)

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
    save(prefetched(link)&.records&.fetch(id.to_s, nil) || find!(model, id, within: link&.related), part, link)
  end

  # The record identified by `identifying` columns, else by primary key,
  # else `fallback`, else a new one — created with the given id, if any. An
  # id of a record it may not reach is an error, not a new record.
  def upsert(model, input, link: nil, identifying: nil, fallback: nil)
    part = partition(model, input)
    within = link&.related
    record = identifying.nil? ? nil : find_identified(model, part, identifying, within)
    record ||= find_by_given_key(model, part, within, prefetched(link))
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
  def find_by_given_key(model, part, within, prefetched = nil)
    key, id = part.take_key(model)
    return nil if key.nil?

    if id.nil? || id.to_s.empty?
      part.attributes.delete(key)
      return nil
    end

    record = prefetched ? taken_or_found(model, id, within, prefetched) : lookup_given_key(model, id, within)
    part.attributes[model.primary_key] = part.attributes.delete(key) if record.nil? && key != model.primary_key
    record
  end

  # A narrowed lookup that misses a record that exists is refused: that key is
  # no new record's. Unnarrowed, missing is missing.
  def lookup_given_key(model, id, within)
    scope = reachable(model, within)
    record = scope.find_by(model.primary_key => id)
    narrowed = within || scope.where_clause.any?
    raise ::GraphQL::ExecutionError, missing(model, [id], within) if record.nil? && narrowed && model.exists?(model.primary_key => id)

    record
  end

  def taken_or_found(model, id, within, prefetched)
    raise ::GraphQL::ExecutionError, missing(model, [id], within) if prefetched.taken.include?(id.to_s)

    prefetched.records[id.to_s]
  end

  def prefetched(link) = link && @prefetched&.[](link)

  # Runs the block with the records a list of update or upsert inputs on a
  # parent's association names looked up at once, as find! and an upsert's
  # key would one by one: one query for them, one more for an upsert's keys
  # that miss, whatever the list's length.
  def prefetching(name, model, operation, link)
    keys = prefetchable?(name, operation, link) ? given_keys(model, operation) : []
    return yield if keys.empty?

    (@prefetched ||= {}.compare_by_identity)[link] = prefetch(name, model, keys, link)
    yield
  ensure
    @prefetched&.delete(link) if link
  end

  def prefetchable?(name, operation, link) = link && %w[update upsert].include?(name) && operation.identifying.nil?

  def prefetch(name, model, keys, link)
    key = model.primary_key
    records = reachable(model, link.related).where(key => keys).index_by { |record| record[key].to_s }
    absent = keys - records.keys
    taken = name == 'upsert' && absent.any? ? model.where(key => absent).pluck(key).map(&:to_s) : []
    Prefetched.new(records, taken.to_set)
  end

  # The primary keys a list of inputs gives, as strings.
  def given_keys(model, operation)
    names = ['id', model.primary_key].uniq.map(&:to_sym)
    operation.inputs.filter_map { |input| names.filter_map { |name| input.args[name] }.first&.to_s.presence }.uniq
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
    prefetching(name, model, operation, link) do
      operation.inputs.each { |input| write(name, model, input, operation, link: link) }
    end
  end
end
