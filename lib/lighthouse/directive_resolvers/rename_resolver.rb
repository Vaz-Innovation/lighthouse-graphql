# frozen_string_literal: true

require_relative 'base'

# @rename(attribute: "snake_case_name") — explicit override of the default
# field reader. Reads the named attribute off the parent object regardless
# of the GraphQL field name.
class Lighthouse::GraphQL::DirectiveResolvers::RenameDirectiveResolver < Lighthouse::GraphQL::DirectiveResolvers::BaseDirectiveResolver
  def self.directive_name = 'rename'
  def self.definition = 'directive @rename(attribute: String!) on FIELD_DEFINITION | ARGUMENT_DEFINITION | INPUT_FIELD_DEFINITION'

  def define_resolver(target_type_class)
    method_name = "resolve_field_#{@field_def.name}"
    attribute = Lighthouse::Support::DirectiveArgs.literal(@directive_node, 'attribute').to_s

    resolver = lambda do |obj, _arguments, _ctx|
      next nil if obj.nil?

      if obj.is_a?(Hash)
        obj[attribute] || obj[attribute.to_sym]
      elsif obj.respond_to?(attribute)
        obj.public_send(attribute)
      end
    end

    target_type_class.define_singleton_method(method_name, &resolver)
    @field_def.resolve_proc = resolver if @field_def.respond_to?(:resolve_proc=)
  end
end
