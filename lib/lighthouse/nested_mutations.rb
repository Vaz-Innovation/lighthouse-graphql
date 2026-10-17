# frozen_string_literal: true

module Lighthouse
  module GraphQL
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
    module NestedMutations
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

      # One level of input: the values (snake_case symbol keys), the GraphQL
      # argument definitions they were given against, and their GraphQL path.
      Input = Struct.new(:values, :argument_defs, :path)

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

      class Executor
        def initialize(field_name)
          @field_name = field_name
        end

        def create(model, input, link: nil)
          save(model.new, partition(model, input), link)
        end

        def update(model, input, link: nil)
          part = partition(model, input)
          key, id = part.take_key(model)
          raise ::GraphQL::ExecutionError, MISSING_PRIMARY_KEY if key.nil? || id.nil?

          part.attributes.delete(key)
          save(find!(model, id), part, link)
        end

        # The record identified by `identifying` columns, else by primary key,
        # else `fallback`, else a new one — created with the given id, if any.
        def upsert(model, input, link: nil, identifying: nil, fallback: nil)
          part = partition(model, input)
          record = identifying.nil? ? nil : find_identified(model, part, identifying)

          if record.nil? && (taken = part.take_key(model))
            key, id = taken
            if id.nil? || id.to_s.empty?
              part.attributes.delete(key)
            else
              record = model.find_by(model.primary_key => id)
              part.attributes[model.primary_key] = part.attributes.delete(key) if record.nil? && key != model.primary_key
            end
          end

          save(record || fallback || model.new, part, link)
        end

        def find!(model, id)
          model.find_by(model.primary_key => id) ||
            raise(::GraphQL::ExecutionError, "Couldn't find #{model.name} with '#{model.primary_key}'=#{id}")
        end

        # Assign, run the operations that set this record's foreign keys, save
        # once, then run the operations on associations pointing back at it.
        def save(record, part, link = nil)
          record.assign_attributes(part.attributes)
          deferred_deletes = []
          before, after = part.operations.partition { |reflection, _| owner_side?(reflection) }

          before.each { |reflection, operations| belongs_to(record, reflection, operations, deferred_deletes) }
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

        # ----------------------------------------------------------------------
        # Splitting input into attributes and operations

        def partition(model, input)
          part = Partition.new(argument_paths(input.argument_defs, input.path))
          walk(model, input, part)
          part
        end

        def walk(model, input, part)
          by_keyword = Lighthouse::Support::Arguments.keyword_index(input.argument_defs)
          input.values.each do |key, value|
            argument = by_keyword[key.to_sym]
            path = input.path + [argument ? argument.graphql_name : key.to_s.camelize(:lower)]
            attribute = (argument && renamed(argument)) || key.to_s
            directive = argument && nested_directive(argument)

            if argument && Lighthouse::Support::Arguments.spread?(argument)
              walk(model, Input.new(Lighthouse::Support::Arguments.shallow(value), argument.type.unwrap.arguments, path), part) unless value.nil?
            elsif directive
              next if value.nil?

              reflection = reflection!(model, Lighthouse::Support::DirectiveArgs.literal(directive, 'relation') || attribute)
              identifying = (Array(Lighthouse::Support::DirectiveArgs.literal(directive, 'identifyingColumns')) if directive.arguments.any? { |a| a.name == 'identifyingColumns' })
              part.add(reflection, ARGUMENT_DIRECTIVES[directive.name] => Operation.new(value, argument, path, identifying))
            elsif (reflection = relation_argument(model, attribute, argument))
              part.add(reflection, operations(model, reflection, argument, value, path)) unless value.nil?
            else
              part.attributes[attribute] = Lighthouse::Support::Arguments.plain(value)
              part.paths[attribute] ||= path.join('.')
            end
          end
        end

        # An association-named argument whose type is an input object of operations.
        def relation_argument(model, attribute, argument)
          return nil unless argument && argument.type.unwrap.kind.input_object?
          return nil unless model.respond_to?(:reflect_on_association)

          model.reflect_on_association(attribute.to_sym)
        end

        def operations(model, reflection, argument, value, path)
          allowed = OPERATIONS.fetch(kind(reflection))
          by_keyword = Lighthouse::Support::Arguments.keyword_index(argument.type.unwrap.arguments)
          Lighthouse::Support::Arguments.shallow(value).each_with_object({}) do |(key, operation_value), out|
            next if operation_value.nil?

            operation_argument = by_keyword[key.to_sym]
            name = operation_argument&.graphql_name || key.to_s.camelize(:lower)
            unless allowed.include?(name)
              raise Lighthouse::DefinitionError,
                    "#{name} is not a nested operation on #{model}##{reflection.name} (#{kind(reflection)}): use #{allowed.join(', ')}."
            end

            out[name] = Operation.new(operation_value, operation_argument, path + [name])
          end
        end

        def nested_directive(argument)
          (argument.ast_node&.directives || []).find { |d| ARGUMENT_DIRECTIVES.key?(d.name) }
        end

        def reflection!(model, name)
          model.reflect_on_association(name.to_s.underscore.to_sym) ||
            raise(Lighthouse::DefinitionError, "#{model} has no association #{name} for a nested mutation.")
        end

        def renamed(argument)
          directive = (argument.ast_node&.directives || []).find { |d| d.name == 'rename' }
          directive && Lighthouse::Support::DirectiveArgs.literal(directive, 'attribute')
        end

        # { attribute => "argument.path" } for every argument the type defines —
        # also those the client left out, where e.g. a presence error belongs.
        def argument_paths(argument_defs, prefix)
          paths = Hash.new { |_, attribute| (prefix + [attribute.to_s.camelize(:lower)]).join('.') }
          (argument_defs || {}).each_value do |argument|
            if Lighthouse::Support::Arguments.spread?(argument)
              paths.merge!(argument_paths(argument.type.unwrap.arguments, prefix + [argument.graphql_name]))
            else
              paths[renamed(argument) || argument.keyword.to_s] = (prefix + [argument.graphql_name]).join('.')
            end
          end
          paths
        end

        def base_path(paths)
          prefix = paths.default_proc.call({}, '').delete_suffix('.')
          prefix.empty? ? @field_name : prefix
        end

        # ----------------------------------------------------------------------
        # Operations

        def kind(reflection)
          case reflection.macro
          when :belongs_to then reflection.polymorphic? ? :morph_to : :belongs_to
          when :has_one
            raise Lighthouse::DefinitionError, "#{reflection.name}: nested mutations on has_one :through are not supported." if reflection.through_reflection?

            :has_one
          when :has_many then reflection.through_reflection? ? :many_to_many : :has_many
          when :has_and_belongs_to_many then :many_to_many
          end
        end

        def owner_side?(reflection)
          %i[belongs_to morph_to].include?(kind(reflection))
        end

        def belongs_to(record, reflection, operations, deferred_deletes)
          association = record.association(reflection.name)
          in_order(reflection, operations).each do |name, operation|
            case name
            when 'create' then association.writer(create(reflection.klass, operation.input))
            when 'update' then association.writer(update(reflection.klass, operation.input))
            when 'upsert' then association.writer(upsert(reflection.klass, operation.input, identifying: operation.identifying))
            when 'connect' then connect_owner(record, reflection, operation.plain)
            when 'disconnect' then association.writer(nil) if operation.truthy?
            when 'delete'
              next unless operation.truthy?

              related = record.public_send(reflection.name)
              association.writer(nil)
              deferred_deletes << related if related
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

        # The model a morphTo `connect` names: a class name, resolved like any
        # model name, or an enum value such as TASK for Task.
        def morph_model(type)
          [type, type.to_s.downcase.camelize].uniq.each do |name|
            model = Lighthouse::Support::ModelResolver.constantize(name)
            return model if model.is_a?(Class) && model < ::ActiveRecord::Base
          end

          raise ::GraphQL::ExecutionError, "Unknown type #{type} to connect."
        end

        def dependents(record, reflection, operations)
          case kind(reflection)
          when :has_one then has_one(record, reflection, operations)
          when :has_many then has_many(record, reflection, operations)
          when :many_to_many then many_to_many(record, reflection, operations)
          end
        end

        def has_one(record, reflection, operations)
          model = reflection.klass
          link = HasLink.new(record, reflection)
          existing = -> { record.association(reflection.name).scope.first }

          in_order(reflection, operations).each do |name, operation|
            case name
            when 'create'
              if existing.call
                raise ::GraphQL::ExecutionError,
                      "Cannot create a related model: a #{model.name.demodulize} already exists for this " \
                      "#{record.class.name.demodulize}. Use upsert to modify the existing model."
              end
              create(model, operation.input, link: link)
            when 'update' then update(model, operation.input, link: link)
            when 'upsert'
              upsert(model, operation.input, link: link, fallback: existing.call, identifying: operation.identifying)
            when 'delete'
              # An ID, or — as for any single relation — a Boolean meaning "the current one".
              if [true, false].include?(operation.value)
                existing.call&.destroy! if operation.value
              else
                model.where(model.primary_key => operation.plain).destroy_all
              end
            end
          end
        end

        def has_many(record, reflection, operations)
          model = reflection.klass
          link = HasLink.new(record, reflection)

          in_order(reflection, operations).each do |name, operation|
            case name
            when 'create' then operation.inputs.each { |input| create(model, input, link: link) }
            when 'update' then operation.inputs.each { |input| update(model, input, link: link) }
            when 'upsert' then operation.inputs.each { |input| upsert(model, input, link: link, identifying: operation.identifying) }
            when 'connect'
              model.where(model.primary_key => operation.plain).each do |child|
                link.before_save(child)
                persist!(child, Hash.new { operation.path.join('.') })
              end
            when 'disconnect'
              model.where(model.primary_key => operation.plain).each do |child|
                child[reflection.foreign_key] = nil
                persist!(child, Hash.new { operation.path.join('.') })
              end
            when 'delete' then model.where(model.primary_key => operation.plain).destroy_all
            end
          end
        end

        def many_to_many(record, reflection, operations)
          model = reflection.klass
          pivot = Pivot.new(record, reflection)
          link = AttachLink.new(pivot)

          in_order(reflection, operations).each do |name, operation|
            case name
            when 'sync' then pivot.sync(pairs(operation), detaching: true)
            when 'syncWithoutDetaching' then pivot.sync(pairs(operation), detaching: false)
            when 'create' then operation.inputs.each { |input| create(model, input, link: link) }
            when 'update' then operation.inputs.each { |input| update(model, input, link: link) }
            when 'upsert' then operation.inputs.each { |input| upsert(model, input, link: link, identifying: operation.identifying) }
            when 'delete'
              pivot.detach(operation.plain)
              model.where(model.primary_key => operation.plain).destroy_all
            when 'connect' then pairs(operation).each { |id, values| pivot.attach(id, values) }
            when 'disconnect' then pivot.detach(operation.plain)
            end
          end
          pivot.reset
        end

        # PHP Lighthouse's fixed order, whatever order the client wrote them in.
        def in_order(reflection, operations)
          OPERATIONS.fetch(kind(reflection)).filter_map { |name| [name, operations[name]] if operations[name] }
        end

        # [[id, pivot values], ...] from a list of IDs or of { id, ...pivot } inputs.
        def pairs(operation)
          Array(operation.plain).map do |item|
            next [item, {}] unless item.is_a?(Hash)

            values = item.transform_keys(&:to_s)
            [values.delete('id'), values]
          end
        end

        private

        def find_identified(model, part, columns)
          if columns.empty?
            raise Lighthouse::DefinitionError, "@upsert's identifyingColumns must not be empty."
          end

          values = columns.to_h { |column| [column.to_s, part.attributes[column.to_s]] }
          raise ::GraphQL::ExecutionError, MISSING_IDENTIFYING_COLUMNS if values.values.any?(&:nil?)

          model.find_by(values)
        end
      end
    end
  end
end
