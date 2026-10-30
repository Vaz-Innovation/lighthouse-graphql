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
# `id_from_object`, as graphql-ruby's Node `id` does. It decodes one as PHP
# Lighthouse's GlobalId does, without reading the database: Rails' GlobalID
# names the model and the id. Only an id of another format is decoded
# through `object_from_id`, which loads the record.
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

  # [type, id] for a global id a client sent, from Rails' GlobalID or the
  # schema's object_from_id (schema_ids?), else Config.global_id; a
  # GraphQL::ExecutionError when it is not one.
  def decode!(global_id, context = nil)
    type, id = schema_ids?(context&.schema) ? decode_schema_id(global_id, context) : Lighthouse::Config.global_id.decode(global_id)
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

  # A Rails GlobalID (`to_gid_param`, graphql-ruby's install's
  # id_from_object) names its model and id, so the record needs no SELECT,
  # and one a default scope hides (a soft-deleted record @restore looks for)
  # decodes too. Any other id goes through object_from_id.
  def decode_schema_id(global_id, context)
    gid = defined?(::GlobalID) && global_id.is_a?(String) ? ::GlobalID.parse(global_id) : nil
    gid ? [gid.model_name.demodulize, gid.model_id] : decode_object(global_id, context)
  end

  # Is `global_id`, decoded as `type`, an id of `model` or of a subclass (STI)?
  # A Rails GlobalID names its model class; another names a GraphQL type, whose
  # model is its @model(class:), else the class of its name.
  def of_model?(global_id, type, model, context)
    klass = rails_model(global_id) || type_model(type, context)
    klass.is_a?(Class) && klass <= model
  end

  def rails_model(global_id)
    return unless defined?(::GlobalID) && global_id.is_a?(String)

    ::GlobalID.parse(global_id)&.model_class
  rescue NameError
    nil
  end

  # The model of the GraphQL type (or model) named `name`.
  def type_model(name, context)
    Lighthouse::Support::ModelResolver.constantize(declared_model(name, context) || name)
  end

  # The @model(class:) of the schema's type of that name.
  def declared_model(name, context)
    schema_type = context.schema.get_type(name.to_s) if context.respond_to?(:schema) && context.schema
    directives = schema_type.respond_to?(:ast_node) ? schema_type.ast_node&.directives : nil
    Lighthouse::Support::DirectiveArgs.literal(directives&.find { |d| d.name == 'model' }, 'class')
  end

  # [type, id] of the object the schema's object_from_id finds.
  def decode_object(global_id, context)
    object = context.schema.object_from_id(global_id, context)
    object.nil? ? [] : [object.class.name.demodulize, object.id]
  end
end
