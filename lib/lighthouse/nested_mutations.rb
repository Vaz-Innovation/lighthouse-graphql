# frozen_string_literal: true

# Nested mutations — PHP Lighthouse's nested arg resolvers, over ActiveRecord.
#
# An input field named after an association of the model being saved (or an
# argument with @create/@update/@upsert/@delete(relation:)) carries operations
# on that association instead of an attribute:
#
#   belongsTo / morphTo            connect, create, update, upsert, disconnect, delete
#   hasOne / morphOne              create, update, upsert, delete
#   hasMany / morphMany            create, update, upsert, connect, disconnect, delete
#   belongsToMany / morphToMany    sync, syncWithoutDetaching, create, update, upsert,
#                                  delete, connect, disconnect
#
# Each record is saved once: attributes are assigned, belongsTo/morphTo
# operations set its foreign keys, it is saved, then the operations on
# associations that point back at it run. Errors are keyed by the full
# GraphQL path of the input (`input.author.create.name`).
#
# As in PHP Lighthouse, `update`, `upsert`, `delete` and `disconnect` find
# records by primary key in the whole table, not only among the parent's
# current children — an `update` re-parents the record it finds. Authorize
# the mutation field accordingly.
module Lighthouse::GraphQL::NestedMutations
  MISSING_PRIMARY_KEY = 'Missing primary key for update.'
  MISSING_IDENTIFYING_COLUMNS = 'All configured identifying columns must be present and non-null for upsert.'

  # Argument directives that make an argument a nested operation, by the
  # operation they stand for.
  ARGUMENT_DIRECTIVES = {
    'create' => 'create', 'createMany' => 'create',
    'update' => 'update', 'updateMany' => 'update',
    'upsert' => 'upsert', 'upsertMany' => 'upsert',
    'delete' => 'delete'
  }.freeze

  OPERATIONS = {
    belongs_to: %w[create connect update upsert disconnect delete],
    morph_to: %w[connect disconnect delete],
    has_one: %w[create update upsert delete],
    has_many: %w[create update upsert connect disconnect delete],
    many_to_many: %w[sync syncWithoutDetaching create update upsert delete connect disconnect]
  }.freeze

  # The PHP Lighthouse relation kind an association stands for, a key of OPERATIONS.
  def self.kind(reflection)
    case reflection.macro
    when :belongs_to then reflection.polymorphic? ? :morph_to : :belongs_to
    when :has_one then one_to_one_kind(reflection)
    when :has_many then reflection.through_reflection? ? :many_to_many : :has_many
    when :has_and_belongs_to_many then :many_to_many
    end
  end

  def self.one_to_one_kind(reflection)
    return :has_one unless reflection.through_reflection?

    raise Lighthouse::DefinitionError, "#{reflection.name}: nested mutations on has_one :through are not supported."
  end
  private_class_method :one_to_one_kind

  # One level of input: the argument values (snake_case symbol keys), the
  # GraphQL argument definitions they were given against, and their GraphQL path.
  Input = Struct.new(:args, :argument_defs, :path)

  # A nested operation's value, the argument it was given as, and — for an
  # @upsert(identifyingColumns:) argument — the columns that identify records.
  Operation = Struct.new(:value, :argument, :path, :identifying) do
    def plain
      Lighthouse::Support::Arguments.plain(value)
    end

    def input(value = self.value, path = self.path)
      Input.new(Lighthouse::Support::Arguments.shallow(value), argument.type.unwrap.arguments, path)
    end

    # A list's items (a single object counts as a list of one).
    def inputs
      return [input] unless value.is_a?(Array)

      value.each_with_index.map { |item, index| input(item, path + [index.to_s]) }
    end

    def truthy?
      value && value != false
    end
  end

  # A record's input split into attributes and association operations.
  class Partition
    attr_reader :attributes, :paths, :operations

    def initialize(paths)
      @attributes = {}
      @paths = paths
      @operations = {} # reflection => { "create" => Operation, ... }
    end

    def add(reflection, operations)
      (@operations[reflection] ||= {}).merge!(operations)
    end

    def take_key(model)
      key = ['id', model.primary_key].uniq.find { |k| @attributes.key?(k) }
      key && [key, @attributes[key]]
    end
  end

  # Sets a child's foreign key (and morph type) to its hasOne/hasMany owner.
  HasLink = Struct.new(:owner, :reflection) do
    def before_save(child)
      child[reflection.foreign_key] = owner[reflection.active_record_primary_key]
      child[reflection.type] = owner.class.polymorphic_name if reflection.type
    end

    def after_save(_child); end
  end

  # Attaches a saved child to a many-to-many owner, keeping existing links.
  AttachLink = Struct.new(:pivot) do
    def before_save(_child); end

    def after_save(child)
      pivot.attach(child.id)
    end
  end

  # The join records of a belongsToMany / morphToMany association:
  # has_many :through (whose join model may carry pivot columns) or
  # has_and_belongs_to_many.
  class Pivot
    def initialize(owner, reflection)
      @owner = owner
      @reflection = reflection
      @through = reflection.through_reflection?
      return unless @through && !reflection.source_reflection.belongs_to?

      raise Lighthouse::DefinitionError,
            "#{owner.class}##{reflection.name} goes through #{reflection.through_reflection.name} to a " \
            "#{reflection.source_reflection.macro}; nested mutations need a join model that belongs_to #{reflection.klass}."
    end

    def ids
      (@through ? joins.where(source_type_condition).pluck(source_key) : @owner.public_send(@reflection.name).pluck(@reflection.klass.primary_key))
        .map(&:to_s)
    end

    # Attach `id` unless attached already; with pivot values, set them either way.
    def attach(id, pivot = {})
      if @through
        join = joins.find_or_initialize_by(source_type_condition.merge(source_key => id))
        join.assign_attributes(pivot)
        join.save! if join.new_record? || join.changed?
      else
        unless pivot.empty?
          raise ::GraphQL::ExecutionError,
                "Pivot values need a has_many :through association; #{@owner.class}##{@reflection.name} is " \
                'has_and_belongs_to_many.'
        end
        @owner.public_send(@reflection.name) << @reflection.klass.find(id) unless ids.include?(id.to_s)
      end
    end

    def detach(ids)
      if @through
        joins.where(source_type_condition.merge(source_key => ids)).destroy_all
      else
        @owner.public_send(@reflection.name).delete(*@reflection.klass.where(@reflection.klass.primary_key => ids).to_a)
      end
    end

    def sync(pairs, detaching:)
      wanted = pairs.map { |id, _| id.to_s }
      stale = ids - wanted
      detach(stale) if detaching && stale.any?
      pairs.each { |id, pivot| attach(id, pivot) }
    end

    def reset
      @owner.association(@reflection.name).reset
      @owner.association(@reflection.through_reflection.name).reset if @through
    end

    private

    def joins
      @owner.public_send(@reflection.through_reflection.name)
    end

    def source_key
      @reflection.source_reflection.foreign_key
    end

    # A join model pointing at the related record polymorphically
    # (`source_type:`) also stores its type.
    def source_type_condition
      source = @reflection.source_reflection
      return {} unless source.polymorphic? && @reflection.options[:source_type]

      { source.foreign_type => @reflection.options[:source_type].to_s.constantize.polymorphic_name }
    end
  end
end

# The executor and its parts open the namespace above compactly, so they load after it.
require_relative 'nested_mutations/partitioner'
require_relative 'nested_mutations/belongs_to_operations'
require_relative 'nested_mutations/has_operations'
require_relative 'nested_mutations/many_to_many_operations'
require_relative 'nested_mutations/executor'
