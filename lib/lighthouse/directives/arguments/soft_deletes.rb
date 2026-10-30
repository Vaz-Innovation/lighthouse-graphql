# frozen_string_literal: true

require_relative 'base'

module Lighthouse::GraphQL::Directives::Arguments
  # @trashed — filter soft-deleted records by the `Trashed` enum the client
  # passes: ONLY the trashed ones, WITH them, or WITHOUT them. When the client
  # omits the argument, the model's own default behaviour is untouched
  # (paranoia hides trashed records, discard shows everything). The model's
  # soft-delete strategy decides what "trashed" is (see Support::SoftDeletes).
  #
  # Usually added by @softDeletes: `tasks: [Task!]! @all @softDeletes`.
  class Trashed < Base
    include Lighthouse::Contracts::SearchBuilder

    TRASHED = { 'ONLY' => :only, 'WITH' => :with, 'WITHOUT' => :without }.freeze

    def self.directive_name = 'trashed'

    def self.definition
      <<~GRAPHQL.chomp
        """
        Allows to filter if trashed elements should be fetched.
        """
        directive @trashed on ARGUMENT_DEFINITION | INPUT_FIELD_DEFINITION
      GRAPHQL
    end

    def handle_builder(relation, value)
      return relation if value.nil?

      Lighthouse::Support::SoftDeletes.filter(relation, value)
    end

    # In a search, the engine decides what trashed records it holds (see Search::Searchkick).
    def handle_search_builder(query, value)
      return query if value.nil?

      Lighthouse::Support::SoftDeletes.require_support!(query.model)
      query.trashed = TRASHED.fetch(value.to_s.upcase) do
        raise ::GraphQL::ExecutionError, "Unknown trashed value #{value.inspect}, expected ONLY, WITH or WITHOUT."
      end
      query
    end
  end

  # @withoutGlobalScopes(names: [...]) — on a Boolean argument: when the client
  # passes `true`, omit the named global scopes from the query.
  #
  # Rails has one anonymous `default_scope`, so each name is resolved as:
  #
  # 1. an app-defined scope `without_<name>` (the name in snake_case) on the
  #    model, e.g. `scope :without_scheduled, -> { unscope(where: :schedule_at) }`;
  # 2. else a column of that name: `unscope(where: column)`. This removes every
  #    condition on that column in the relation, including ones added earlier
  #    by other arguments;
  # 3. else a soft-delete name (`softDeletes`, `SoftDeletingScope`): trashed
  #    records are included (see Support::SoftDeletes).
  #
  # A name matching none of them is an error. A trailing `Scope` is optional in
  # the name (`ScheduledScope` finds `without_scheduled` too).
  class WithoutGlobalScopes < Base
    SOFT_DELETE_NAMES = %w[soft_deletes soft_delete soft_deleting].freeze

    def self.directive_name = 'withoutGlobalScopes'

    def self.definition
      <<~GRAPHQL.chomp
        """
        Omit any number of global scopes from the query builder.

        This directive should be used on arguments of type `Boolean`.
        The scopes will be removed only if `true` is passed by the client.
        """
        directive @withoutGlobalScopes(
          "The names of the global scopes to omit."
          names: [String!]!
        ) on ARGUMENT_DEFINITION | INPUT_FIELD_DEFINITION
      GRAPHQL
    end

    def handle_builder(relation, value)
      return relation unless value == true

      Array(Lighthouse::Support::DirectiveArgs.literal(@directive_node, 'names')).reduce(relation) do |acc, name|
        without_scope(acc, name)
      end
    end

    private

    def without_scope(relation, name)
      candidates = candidate_names(name)
      omit_by_scope(relation, candidates) || omit_by_column(relation, candidates) || omit_trashed(relation, candidates) ||
        raise(::GraphQL::ExecutionError, unknown_scope(relation, name, candidates.first))
    end

    def omit_by_scope(relation, candidates)
      scope = candidates.map { |candidate| "without_#{candidate}" }.find { |method| relation.respond_to?(method) }
      scope && (relation.public_send(scope) || relation)
    end

    def omit_by_column(relation, candidates)
      column = candidates.find { |candidate| column?(relation, candidate) }
      column && relation.unscope(where: column)
    end

    def omit_trashed(relation, candidates)
      Lighthouse::Support::SoftDeletes.with_trashed(relation) if candidates.intersect?(SOFT_DELETE_NAMES)
    end

    def unknown_scope(relation, name, candidate)
      "Cannot omit the global scope #{name}: #{relation.klass.name} has no without_#{candidate} scope or #{candidate} column."
    end

    def candidate_names(name)
      snake = Lighthouse::Support::Naming.attribute(name)
      [snake, snake.delete_suffix('_scope')].uniq
    end

    def column?(relation, name)
      relation.klass.column_names.include?(name)
    rescue ::ActiveRecord::ActiveRecordError
      false
    end
  end
end
