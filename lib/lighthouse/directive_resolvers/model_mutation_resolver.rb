# frozen_string_literal: true

require_relative 'base'

module Lighthouse
  module GraphQL
    module DirectiveResolvers
      # Shared by @create, @createMany, @update, @updateMany, @upsert and
      # @upsertMany: saves the model a field returns through ActiveRecord, so the
      # model's own validations decide what is valid — the Rails way — and nested
      # input on its associations runs as nested mutations (see NestedMutations).
      # Failures raise a Lighthouse::ValidationError keyed by argument path. The
      # whole field runs in one transaction (Config.transactional_mutations).
      #
      # Arguments map to attributes by their snake_case name, or @rename's
      # `attribute:`; @spread merges an input object into its parent; @inject
      # adds server-side values. On an argument, these directives take
      # `relation:` and act on that association of the parent instead.
      class ModelMutationResolver < BaseDirectiveResolver
        ARGUMENTS = 'model: String, relation: String'
        LOCATIONS = 'FIELD_DEFINITION | ARGUMENT_DEFINITION | INPUT_FIELD_DEFINITION'

        def define_resolver(target_type_class)
          me = self
          install(target_type_class, lambda do |obj, args, ctx|
            model = me.send(:model_class)
            me.send(:transaction, model) { me.send(:mutate, model, obj, args, ctx) }
          end)
        end

        protected

        def mutate(_model, _obj, _args, _ctx)
          raise NotImplementedError
        end

        def executor
          NestedMutations::Executor.new(@field_def.name)
        end

        def transaction(model, &block)
          Lighthouse::Config.transactional_mutations ? model.transaction(&block) : block.call
        end

        def field_input(args, ctx)
          values = Lighthouse::Support::Arguments.inject(@field_def.ast_node, Lighthouse::Support::Arguments.shallow(args), ctx)
          NestedMutations::Input.new(values, @field_def.arguments, [])
        end

        NOT_EXACTLY_ONE_ARGUMENT = '@*Many directives must ensure that clients pass exactly one field argument.'
        ARGUMENT_NOT_LIST = '@*Many directives must ensure that the single argument value is a list.'
        LIST_ITEM_NOT_INPUT_OBJECT = '@*Many directives must ensure that the list items of its single argument value are input objects.'

        # The inputs of the single list-of-inputs argument of the *Many directives.
        def item_inputs(args)
          argument = @field_def.arguments.values.first
          raise Lighthouse::DefinitionError, NOT_EXACTLY_ONE_ARGUMENT unless @field_def.arguments.size == 1
          raise Lighthouse::DefinitionError, ARGUMENT_NOT_LIST unless argument.type.list?
          raise Lighthouse::DefinitionError, LIST_ITEM_NOT_INPUT_OBJECT unless argument.type.unwrap.kind.input_object?

          items = Array(Lighthouse::Support::Arguments.shallow(args)[argument.keyword])
          items.each_with_index.map do |item, index|
            NestedMutations::Input.new(Lighthouse::Support::Arguments.shallow(item), argument.type.unwrap.arguments,
                                       [argument.graphql_name, index.to_s])
          end
        end

        # Save every item, then raise once with all their errors (the
        # transaction rolls the saved ones back).
        def each_item(inputs)
          messages = {}
          records = inputs.map do |input|
            yield input
          rescue Lighthouse::ValidationError => e
            messages.merge!(e.messages) { |_, a, b| a + b }
            nil
          end
          raise Lighthouse::ValidationError.new(@field_def.name, messages) unless messages.empty?

          records
        end

        def identifying_columns
          return nil unless @directive_node.arguments.any? { |a| a.name == 'identifyingColumns' }

          Array(directive_arg('identifyingColumns'))
        end

        # An empty list would match any record; refuse it when the schema is built.
        def validate_identifying_columns!
          return unless identifying_columns&.empty?

          raise Lighthouse::DefinitionError,
                "@#{@directive_node.name} on #{@type_def.graphql_name}.#{@field_def.name}: identifyingColumns must not be empty."
        end
      end

      # @create — create a model from the field's arguments.
      class CreateDirectiveResolver < ModelMutationResolver
        def self.directive_name = 'create'
        def self.definition = "directive @create(#{ARGUMENTS}) on #{LOCATIONS}"

        protected

        def mutate(model, _obj, args, ctx) = executor.create(model, field_input(args, ctx))
      end

      # @createMany — create one model per input in the field's single list argument.
      class CreateManyDirectiveResolver < ModelMutationResolver
        def self.directive_name = 'createMany'
        def self.definition = "directive @createMany(#{ARGUMENTS}) on #{LOCATIONS}"

        protected

        def mutate(model, _obj, args, _ctx)
          each_item(item_inputs(args)) { |input| executor.create(model, input) }
        end
      end

      # @update — find a model by its primary key argument and update it.
      class UpdateDirectiveResolver < ModelMutationResolver
        def self.directive_name = 'update'
        def self.definition = "directive @update(#{ARGUMENTS}) on #{LOCATIONS}"

        protected

        def mutate(model, _obj, args, ctx) = executor.update(model, field_input(args, ctx))
      end

      # @updateMany — update one model per input (each carrying its primary key).
      class UpdateManyDirectiveResolver < ModelMutationResolver
        def self.directive_name = 'updateMany'
        def self.definition = "directive @updateMany(#{ARGUMENTS}) on #{LOCATIONS}"

        protected

        def mutate(model, _obj, args, _ctx)
          each_item(item_inputs(args)) { |input| executor.update(model, input) }
        end
      end

      # @upsert — update the model the arguments identify (by `identifyingColumns`,
      # else primary key), or create it.
      class UpsertDirectiveResolver < ModelMutationResolver
        def self.directive_name = 'upsert'
        def self.definition = "directive @upsert(#{ARGUMENTS}, identifyingColumns: [String!]) on #{LOCATIONS}"

        def define_resolver(target_type_class)
          validate_identifying_columns!
          super
        end

        protected

        def mutate(model, _obj, args, ctx)
          executor.upsert(model, field_input(args, ctx), identifying: identifying_columns)
        end
      end

      # @upsertMany — @upsert for each input in the field's single list argument.
      class UpsertManyDirectiveResolver < ModelMutationResolver
        def self.directive_name = 'upsertMany'
        def self.definition = "directive @upsertMany(#{ARGUMENTS}, identifyingColumns: [String!]) on #{LOCATIONS}"

        def define_resolver(target_type_class)
          validate_identifying_columns!
          super
        end

        protected

        def mutate(model, _obj, args, _ctx)
          columns = identifying_columns
          each_item(item_inputs(args)) { |input| executor.upsert(model, input, identifying: columns) }
        end
      end

      # @delete — destroy the models the field's argument filters select
      # (@whereKey, @eq, ...), running their callbacks, and return them: a list
      # for a list field, else the first or null. Refuses to run without a
      # filter argument, which would delete every row.
      class DeleteDirectiveResolver < ModelMutationResolver
        def self.directive_name = 'delete'
        def self.definition = "directive @delete(#{ARGUMENTS}, scopes: [String!]) on #{LOCATIONS}"

        WOULD_MODIFY_ALL = 'Would modify all models, use an argument to filter.'

        protected

        # A record whose callbacks refuse the destroy is reported as an error next
        # to the data, as PHP Lighthouse does; the others are still deleted.
        def mutate(model, _obj, args, ctx)
          args = Lighthouse::Support::Arguments.shallow(args)
          raise ::GraphQL::ExecutionError, WOULD_MODIFY_ALL unless filtered?(args)

          relation = Array(directive_arg('scopes')).reduce(model.all) { |acc, scope| acc.public_send(scope) }
          records = apply_where_filters(relation, args).to_a
          records.each do |record|
            next if record.destroy

            ctx.add_error(::GraphQL::ExecutionError.new("Could not modify model #{model.name} with ID #{record.id}."))
          end
          @field_def.type.list? ? records : records.first
        end

        def filtered?(args)
          registry = Lighthouse::DirectiveRegistry.default
          (@field_def.ast_node.arguments || []).any? do |argument|
            args.key?(argument.name.underscore.to_sym) && argument.directives.any? { |d| registry.arg_builder_class(d.name) }
          end
        end
      end
    end
  end
end
