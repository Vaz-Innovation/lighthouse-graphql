# frozen_string_literal: true

require_relative 'base'

# @globalId — Relay global ids, as PHP Lighthouse's directive: on a field it
# encodes the value with the type's name (`id: ID! @globalId` answers
# "VXNlcjox" for User 1); on an argument or input field it decodes what the
# client sent (ArgumentTransformsResolver). Config.global_id does the encoding.
# Unlike PHP Lighthouse's, a decoded id is checked to be of the type it is
# for: `type:`, or with decode: ID the field's model when the argument filters
# its key (GlobalIdTypes), so another type's id fails rather than finds the
# record of the same number.
class Lighthouse::GraphQL::DirectiveResolvers::GlobalIdDirectiveResolver < Lighthouse::GraphQL::DirectiveResolvers::BaseDirectiveResolver
  NAME = 'globalId'

  def self.directive_name = NAME

  def self.definition
    <<~GRAPHQL.chomp
      """
      Converts between IDs/types and global IDs.

      When used upon a field, it encodes;
      when used upon an argument, it decodes.
      """
      directive @globalId(
        """
        Decoding a global id produces a tuple of `$type` and `$id`.
        This setting controls which of those is passed along.
        """
        decode: GlobalIdDecode = ARRAY
        "The type (GraphQL type or model) a decoded id must be of. Inferred for a key of the field's model."
        type: String
      ) on FIELD_DEFINITION | INPUT_FIELD_DEFINITION | ARGUMENT_DEFINITION
    GRAPHQL
  end

  def self.type_definitions
    {
      'GlobalIdDecode' => <<~GRAPHQL.chomp
        "Options for the `decode` argument of `@globalId`."
        enum GlobalIdDecode {
          "Return an array of `[$type, $id]`."
          ARRAY
          "Return just `$type`."
          TYPE
          "Return just `$id`."
          ID
        }
      GRAPHQL
    }
  end

  def define_resolver(target_type_class)
    inner = capture_inner(target_type_class)
    type_name = target_type_class.graphql_name

    install(target_type_class, lambda do |obj, args, ctx|
      id = inner.call(obj, args, ctx)
      next if id.nil?

      Lighthouse::GraphQL::GlobalId.encode_field(target_type_class, obj, id, ctx) || Lighthouse::Config.global_id.encode(type_name, id)
    end)
  end
end
