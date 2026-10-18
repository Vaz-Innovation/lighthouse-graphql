# frozen_string_literal: true

require 'active_support/concern'

# Hands a graphql-ruby type class to Lighthouse, as `include
# Lighthouse::GraphQL::Subscription` does a subscription. The class keeps
# graphql-ruby's folder structure and naming (app/graphql/types/post_type.rb,
# Types::PostType for the SDL's Post type) and base classes, and does for the
# SDL type of its name what it does in a graphql-ruby schema:
#
#   class Types::PostType < Types::BaseObject              # an object type
#     include Lighthouse::GraphQL::Type
#
#     def reading_time = { words: object.body.to_s.split.size }
#   end
#
#   class Types::SearchResultType < Types::BaseUnion       # a union
#     include Lighthouse::GraphQL::Type
#
#     def self.resolve_type(object, context) = object.is_a?(Post) ? 'Post' : 'User'
#   end
#
#   module Types::NamedType                                 # an interface
#     include Types::BaseInterface
#     include Lighthouse::GraphQL::Type
#
#     definition_methods do
#       def resolve_type(object, context) = ...
#     end
#   end
#
#   class Types::DateTimeType < Types::BaseScalar           # a scalar
#     include Lighthouse::GraphQL::Type
#
#     def self.coerce_input(value, context) = Time.iso8601(value)
#     def self.coerce_result(value, context) = value.iso8601
#   end
#
# An object type's methods resolve its fields that have no resolving
# directive, with graphql-ruby's `object` (the parent), `context`, the
# `dataload*` helpers, and the field's arguments as snake_case keywords. A
# union's or interface's `resolve_type` picks the object type of a value (a
# type name, or a type class such as Types::PostType). A scalar's
# `coerce_input` / `coerce_result` convert its values. The SDL still declares
# the types and their fields: the class only lends its behaviour, so `field`
# declarations in it are ignored, and an object type's `authorized?` does not run.
#
# The model an object type resolves is the SDL's to say, with @model(class:).
#
# A Types::<Name>Type that does not include the concern is not Lighthouse's,
# and is left alone.
module Lighthouse::GraphQL::Type
  extend ActiveSupport::Concern

  # The kinds of graphql-ruby class the concern can be included in.
  KINDS = {
    object: ::GraphQL::Schema::Object,
    union: ::GraphQL::Schema::Union,
    scalar: ::GraphQL::Schema::Scalar,
    interface: ::GraphQL::Schema::Interface
  }.freeze

  # :object, :union, :scalar or :interface for a graphql-ruby type class or
  # interface module; nil for anything else.
  def self.kind_of(mod)
    return :interface if !mod.is_a?(Class) && mod.is_a?(Module) && mod.include?(KINDS[:interface])
    return unless mod.is_a?(Class)

    %i[object union scalar].find { |kind| mod < KINDS[kind] }
  end

  # The class of the SDL type `type_name` (`Types::PostType` for `Post`) in
  # Config.namespaces[:types], when it includes the concern; nil otherwise. The
  # class must be of the same `kind` as the SDL type.
  def self.class_for(type_name, kind)
    klass = Lighthouse::Support::ModelResolver.constantize("#{type_name}Type", namespaces: Lighthouse::Config.namespaces[:types],
                                                                               fallback: false)
    return unless klass.is_a?(Module) && klass.include?(self) && kind_of(klass)
    return klass if kind_of(klass) == kind

    raise Lighthouse::DefinitionError, "#{klass} is a type class of kind #{kind_of(klass)}, but #{type_name} is of kind #{kind} in the schema."
  end

  # What the SDL's types take from their classes and directives, once the
  # schema is built: every @model names a model (ModelDirective), every @union /
  # @interface class exists and every type class matches its kind and base
  # (TypeResolution), and every scalar with a class reads and writes its values
  # through it (ScalarCoercion). `bases`: the schema's base_types, by kind.
  def self.apply(schema, bases = {})
    Lighthouse::GraphQL::Directives::ModelDirective.validate!(schema)
    Lighthouse::GraphQL::TypeResolution.validate!(schema, bases)
    Lighthouse::GraphQL::ScalarCoercion.apply(schema, bases[:scalar])
    Lighthouse::GraphQL::EnumDirective.apply(schema)
  end

  included do
    unless Lighthouse::GraphQL::Type.kind_of(self)
      raise Lighthouse::DefinitionError,
            "#{self} includes Lighthouse::GraphQL::Type, which is for graphql-ruby types: a subclass of GraphQL::Schema::Object, " \
            'Union or Scalar, or a module including GraphQL::Schema::Interface (class Types::PostType < Types::BaseObject).'
    end
  end
end
