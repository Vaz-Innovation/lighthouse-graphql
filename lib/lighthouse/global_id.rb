# frozen_string_literal: true

require 'base64'

# Relay global ids, as PHP Lighthouse's Base64GlobalId writes them: the type
# name and the id, joined by a colon, in base64 ("User:1" -> "VXNlcjox").
# Config.global_id takes another object with `encode(type, id)` and
# `decode(global_id)` -> [type, id], as PHP Lighthouse lets the GlobalId
# contract be rebound.
#
# A schema that implements graphql-ruby's Relay ids, `id_from_object` and
# `object_from_id` (graphql-ruby's install writes them, on Rails' GlobalID),
# has one kind of global id: @globalId encodes an object's own id with
# `id_from_object`, and decodes with `object_from_id`, as graphql-ruby's
# Query.node and Node's `id` do.
module Lighthouse::GraphQL::GlobalId
  module_function

  def encode(type, id)
    Base64.strict_encode64("#{type}:#{id}")
  end

  def decode(global_id)
    Base64.strict_decode64(global_id.to_s).split(':', 2)
  rescue ArgumentError
    []
  end

  # [type, id] for a global id a client sent, through the schema's
  # object_from_id (schema_ids?) or Config.global_id; a
  # GraphQL::ExecutionError when it is not one.
  def decode!(global_id, context = nil)
    type, id = schema_ids?(context&.schema) ? decode_object(global_id, context) : Lighthouse::Config.global_id.decode(global_id)
    return [type, id] if type.present? && !id.nil?

    raise ::GraphQL::ExecutionError, "#{global_id.inspect} is not a valid global id."
  end

  # The global id of `object`'s own id (`id`, what a field of `type` resolved)
  # through the schema's id_from_object (schema_ids?); nil for anything else.
  def encode_field(type, object, id, context)
    return unless schema_ids?(context&.schema) && object.respond_to?(:id) && object.id.to_s == id.to_s

    context.schema.id_from_object(object, type, context)
  end

  # Does `schema` define graphql-ruby's object_from_id (GraphQL::Schema's own raises)?
  def schema_ids?(schema)
    schema.respond_to?(:object_from_id) && schema.method(:object_from_id).owner != ::GraphQL::Schema.singleton_class
  end

  # [type, id] of the object the schema's object_from_id finds.
  def decode_object(global_id, context)
    object = context.schema.object_from_id(global_id, context)
    object.nil? ? [] : [object.class.name.demodulize, object.id]
  end
end
