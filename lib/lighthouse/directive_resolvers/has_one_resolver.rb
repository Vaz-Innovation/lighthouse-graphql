# frozen_string_literal: true

require_relative 'base'

module Lighthouse
  module GraphQL
    module DirectiveResolvers
      # @hasOne(relation: "name") — resolve a one-to-one association on the parent
      # object. Mirrors @belongsTo (single record) and batch-loads through the
      # AssociationLoader when a dataloader is available.
      class HasOneDirectiveResolver < BaseDirectiveResolver
        def self.directive_name = 'hasOne'
        def self.definition = 'directive @hasOne(relation: String, scopes: [String!]) on FIELD_DEFINITION'

        def define_resolver(target_type_class)
          field_name = @field_def.name
          assoc_name = directive_arg('relation') || field_name
          method_name = "resolve_field_#{field_name}"

          resolver = lambda do |obj, _arguments, ctx|
            next nil if obj.nil?

            if ctx && ctx.respond_to?(:dataloader) && ctx.dataloader
              loader = ctx.dataloader.with(Lighthouse::GraphQL::DataloaderSources::AssociationLoader, obj.class, assoc_name)
              loader.load(obj)
            elsif obj.respond_to?(assoc_name)
              obj.public_send(assoc_name)
            end
          end

          target_type_class.define_singleton_method(method_name, &resolver)
          @field_def.resolve_proc = resolver if @field_def.respond_to?(:resolve_proc=)
        end

        private

        def directive_arg(name)
          Lighthouse::Support::DirectiveArgs.literal(@directive_node, name)
        end
      end
    end
  end
end
