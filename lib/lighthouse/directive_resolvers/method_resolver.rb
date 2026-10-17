# frozen_string_literal: true

require_relative 'base'

# @method(name: "someMethod") — resolve the field by calling a method on the
# parent object. Mirrors PHP Lighthouse's @method. Defaults to the field's
# own (snake_cased) name when `name` is omitted.
#
#   labels: [String!]! @method(name: "label_list")
#   canReply: Boolean   @method(name: "can_reply?")
class Lighthouse::GraphQL::DirectiveResolvers::MethodDirectiveResolver < Lighthouse::GraphQL::DirectiveResolvers::BaseDirectiveResolver
  def self.directive_name = 'method'
  def self.definition = 'directive @method(name: String) on FIELD_DEFINITION'

  def define_resolver(target_type_class)
    resolver_method = "resolve_field_#{@field_def.name}"
    target_method = (Lighthouse::Support::DirectiveArgs.literal(@directive_node, 'name') ||
                     Lighthouse::Support::Naming.attribute(@field_def.name)).to_s

    resolver = lambda do |obj, _arguments, _ctx|
      next nil if obj.nil?

      obj.respond_to?(target_method) ? obj.public_send(target_method) : nil
    end

    target_type_class.define_singleton_method(resolver_method, &resolver)
    @field_def.resolve_proc = resolver if @field_def.respond_to?(:resolve_proc=)
  end
end
