# frozen_string_literal: true

require_relative 'base'

# Resolves a field of an object type through a method of the type's class, in
# graphql-ruby's folder structure: `Post.readingTime` calls
# `Types::PostType#reading_time` when that class includes Lighthouse::GraphQL::Type
# and defines it. The SDL still declares the field; the class only says how it
# resolves, as a graphql-ruby type's method does: an instance per parent, with
# `object` (the parent), `context`, the `dataload*` helpers, and the field's
# arguments as snake_case keywords. A field with a resolving directive never
# reaches it, and one whose name the class does not define is read off the
# object as before. Not a directive: FieldResolverStack installs it, on the
# root types too (Types::QueryType#latest_posts for Query.latestPosts, before
# the conventional Resolvers::LatestPosts).
class Lighthouse::GraphQL::DirectiveResolvers::TypeMethodResolver < Lighthouse::GraphQL::DirectiveResolvers::BaseDirectiveResolver
  # The class of the SDL type `type_name` (`Types::PostType` for `Post`) in
  # Config.namespaces[:types], when it includes Lighthouse::GraphQL::Type; nil
  # otherwise, so a type class that does not opt in is left alone. It must
  # inherit from the schema's base_types[:object] (in `bases`, ResolverBases)
  # when one is given. A root type's class is the one it is built on (RootTypes).
  def self.type_class(type_name, bases = {}, root_kind = nil)
    return Lighthouse::GraphQL::RootTypes.type_class(root_kind, bases[:roots]) if root_kind

    klass = lookup(type_name)
    return unless klass

    Lighthouse::GraphQL::ResolverBases.check!(klass, bases.dig(:types, :object), "the #{type_name} type")
    klass
  end

  def self.lookup(type_name)
    Lighthouse::GraphQL::Type.class_for(type_name, :object)
  end

  # The method of `klass` that resolves `field_def` (`reading_time` for
  # `readingTime`), or nil. Methods every GraphQL::Schema::Object has
  # (`object`, `context`, Object's own) never count.
  def self.method_for(klass, field_def)
    name = Lighthouse::Support::Naming.attribute(field_def.name)
    name if klass.public_method_defined?(name) && !::GraphQL::Schema::Object.public_method_defined?(name)
  end

  # `root_class`: the root type class the type is built on (RootTypes), used as
  # it is; any other class is looked up by the type's name on each call.
  def initialize(field_def, type_def, method_name, root_class = nil)
    super(field_def, type_def, nil)
    @method_name = method_name
    @root_class = root_class
  end

  def define_resolver(target_type_class)
    Lighthouse::GraphQL::ResolveInfo.request_lookahead(@field_def)
    me = self
    inner = capture_inner(target_type_class)

    install(target_type_class, lambda do |obj, args, ctx|
      me.send(:resolve_with_type, inner, obj, args, ctx)
    end)
  end

  private

  # The class is looked up on each call, so code reloading keeps working; when
  # it no longer defines the method, the field is read as before. A parent that
  # is not a record of the type's @model is reported, and the field resolves to nil.
  def resolve_with_type(inner, obj, args, ctx)
    klass = @root_class || self.class.lookup(@type_def.graphql_name)
    return inner.call(obj, args, ctx) unless klass&.public_method_defined?(@method_name)

    model = Lighthouse::GraphQL::Directives::ModelDirective.declared_model(@type_def)
    return wrong_parent(klass, model, obj, ctx) if model && !obj.is_a?(model)

    info = Lighthouse::GraphQL::ResolveInfo.for(@field_def, @type_def, obj, args, ctx)
    instance = Lighthouse::GraphQL::ResolveInfo.attach(klass.send(:new, obj, ctx), info)
    kwargs = Lighthouse::Support::Arguments.prepare(@field_def, args, ctx)
    kwargs.empty? ? instance.public_send(@method_name) : instance.public_send(@method_name, **kwargs)
  end

  def wrong_parent(klass, model, obj, ctx)
    error = Lighthouse::DefinitionError.new(
      "#{@type_def.graphql_name}.#{@field_def.name} resolves with #{klass}, but its parent is a #{obj.class}, not a #{model} (@model)."
    )
    Lighthouse::Config.handle_error(error, ctx)
    nil
  end
end
