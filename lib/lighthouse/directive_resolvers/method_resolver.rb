# frozen_string_literal: true

require_relative 'base'

# @method(name: "someMethod") — resolve the field by calling a method on the
# parent object. Mirrors PHP Lighthouse's @method. Defaults to the field's
# own (snake_cased) name when `name` is omitted.
#
#   labels: [String!]! @method(name: "label_list")
#   canReply: Boolean   @method(name: "can_reply?")
#   excerpt(length: Int = 80): String @method
#
# The field's arguments reach the method: as snake_case keywords when it takes
# keywords (`def excerpt(length:)`), else positionally in the order the SDL
# declares them, as PHP Lighthouse passes them (`def excerpt(length)`). A method
# taking no parameters is called without them.
class Lighthouse::GraphQL::DirectiveResolvers::MethodDirectiveResolver < Lighthouse::GraphQL::DirectiveResolvers::BaseDirectiveResolver
  def self.directive_name = 'method'
  def self.definition = 'directive @method(name: String) on FIELD_DEFINITION'

  def define_resolver(target_type_class)
    resolver_method = "resolve_field_#{@field_def.name}"
    target_method = (Lighthouse::Support::DirectiveArgs.literal(@directive_node, 'name') ||
                     Lighthouse::Support::Naming.attribute(@field_def.name)).to_s

    field_def = @field_def
    resolver = lambda do |obj, arguments, ctx|
      next nil if obj.nil? || !obj.respond_to?(target_method)

      Lighthouse::GraphQL::DirectiveResolvers::MethodDirectiveResolver.call_method(obj.method(target_method), field_def, arguments, ctx)
    end

    target_type_class.define_singleton_method(resolver_method, &resolver)
    @field_def.resolve_proc = resolver if @field_def.respond_to?(:resolve_proc=)
  end

  KEYWORDS = %i[key keyreq keyrest].freeze
  NAMED_KEYWORDS = %i[key keyreq].freeze

  # Call `method` with the field's arguments, as the method takes them.
  def self.call_method(method, field_def, arguments, ctx)
    params = method.parameters
    return method.call if field_def.arguments.empty? || params.empty?

    values = Lighthouse::Support::Arguments.prepare(field_def, arguments, ctx)
    return method.call(**keywords(params, values)) if params.any? { |type, _| KEYWORDS.include?(type) }

    method.call(*positional(params, field_def, values))
  end

  # The values in the order the SDL declares the arguments, as many as the
  # method takes; all of them when it takes *rest.
  def self.positional(params, field_def, values)
    ordered = field_def.arguments.each_value.map { |arg| values[arg.keyword] }
    params.any? { |type, _| type == :rest } ? ordered : ordered.first(params.size)
  end

  # The values the method's keywords name; all of them when it takes **keywords.
  def self.keywords(params, values)
    return values if params.any? { |type, _| type == :keyrest }

    values.slice(*params.filter_map { |type, name| name if NAMED_KEYWORDS.include?(type) })
  end
end
