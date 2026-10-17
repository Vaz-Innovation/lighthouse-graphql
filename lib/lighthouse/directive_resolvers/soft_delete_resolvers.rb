# frozen_string_literal: true

require_relative 'model_mutation_resolver'

module Lighthouse::GraphQL::DirectiveResolvers
  # The shape of @forceDelete and @restore: like @delete, they act on the
  # records the field's filter arguments select — trashed ones included, which
  # the model's default behaviour may hide — and return them. The model must
  # support soft deletes (see Support::SoftDeletes).
  class TrashedModelsResolver < ModifyModelsResolver
    DOCUMENTED_ARGUMENTS = <<~GRAPHQL.chomp
      "Specify the class name of the model to use. This is only needed when the default model detection does not work."
      model: String
      "Apply scopes to the underlying query."
      scopes: [String!]
    GRAPHQL

    protected

    def records_of(model)
      Lighthouse::Support::SoftDeletes.require_support!(model)
      apply_scopes(Lighthouse::Support::SoftDeletes.with_trashed(model.all))
    end
  end

  # @forceDelete — permanently remove the soft-deleted (or any) models the
  # field's filter arguments select, running their callbacks.
  class ForceDeleteDirectiveResolver < TrashedModelsResolver
    def self.directive_name = 'forceDelete'

    def self.definition
      <<~GRAPHQL.chomp
        """
        Permanently remove one or more soft deleted models.
        """
        directive @forceDelete(
        #{DOCUMENTED_ARGUMENTS.gsub(/^/, '  ')}
        ) on FIELD_DEFINITION
      GRAPHQL
    end

    protected

    def modify(record) = Lighthouse::Support::SoftDeletes.force_delete(record)
  end

  # @restore — un-delete the soft-deleted models the field's filter arguments select.
  class RestoreDirectiveResolver < TrashedModelsResolver
    def self.directive_name = 'restore'

    def self.definition
      <<~GRAPHQL.chomp
        """
        Un-delete one or more soft deleted models.
        """
        directive @restore(
        #{DOCUMENTED_ARGUMENTS.gsub(/^/, '  ')}
        ) on FIELD_DEFINITION
      GRAPHQL
    end

    protected

    def modify(record) = Lighthouse::Support::SoftDeletes.restore(record)
  end
end
