# frozen_string_literal: true

# graphql-ruby's type-level authorization, on the SDL's types: what a
# Types::<Name>Type that includes Lighthouse::GraphQL::Type defines applies to
# every record of its type, whatever field reaches it.
#
#   class Types::PostType < Types::BaseObject
#     include Lighthouse::GraphQL::Type
#
#     # Each Post any field returns. False: the schema's unauthorized_object
#     # (nil by default, so the field is null).
#     def self.authorized?(post, context) = super && PostPolicy.new(context[:current_user], post).show?
#
#     # The Posts Lighthouse queries, in the query itself: pages and counts stay true.
#     def self.scope_items(posts, context) = PostPolicy::Scope.new(context[:current_user], posts).resolve
#   end
#
# `authorized?` runs where graphql-ruby runs it: the SDL's object types whose
# class defines it hand it to the class. `scope_items` runs where Lighthouse
# builds a query for records of the type (BaseDirectiveResolver#apply_where_filters:
# @all, @paginate, @find, @first, @count, @aggregate, the relationship directives,
# enhance_builder), on the batched loads of a relationship and of @find by key
# (DataloaderSources::VisibleRecords, one query per batch), on @withCount's counts
# and on Federation's entity lookups. It gets a relation and must answer one. A
# field that returns no records of a type (@count, @aggregate) is scoped by the
# type of the model it counts, when one type of that model defines scope_items.
#
# Which types define either is read when the schema is built (Index): a type
# without them costs nothing. Rails' reloader rebuilds the schema with the code,
# and the classes themselves are looked up once per query.
module Lighthouse::GraphQL::TypeAuthorization
  MEMO = :lighthouse_type_authorization

  module_function

  # Each object type whose class defines `authorized?` hands it to the class (a
  # root type is built on its class already, RootTypes), and the schema keeps
  # the Index of the ones defining scope_items.
  def apply(schema)
    scoped = []
    each_type_class(schema) do |type, klass|
      delegate_authorized(type) if own?(klass, :authorized?)
      scoped << type if own?(klass, :scope_items)
    end
    index = Index.build(schema, scoped)
    schema.define_singleton_method(:lighthouse_type_authorization) { index }
  end

  # Each object type of the schema with a Lighthouse class, and the class, but
  # the root types and introspection's.
  def each_type_class(schema)
    roots = [schema.query, schema.mutation, schema.subscription].compact
    schema.types.each_value do |type|
      next unless type.kind.object? && !type.graphql_name.start_with?('__') && roots.exclude?(type)

      klass = Lighthouse::GraphQL::Type.class_for(type.graphql_name, :object)
      yield type, klass if klass
    end
  end

  def delegate_authorized(type)
    name = type.graphql_name
    type.define_singleton_method(:authorized?) do |object, context|
      klass = Lighthouse::GraphQL::TypeAuthorization.type_class(name, context)
      klass ? klass.authorized?(object, context) : super(object, context)
    end
  end

  # Does `klass` define `method` (itself or through a base of the app's), not
  # only inherit graphql-ruby's default?
  def own?(klass, method)
    klass.respond_to?(method) && klass.method(method).owner != ::GraphQL::Schema::Object.method(method).owner
  end

  # `relation`, narrowed by the scope_items of the type its records resolve as:
  # the field's return type, else the one type of the relation's model that
  # defines it. A scope_items that answers no relation is the app's error.
  def scope(relation, field_def, context)
    return relation unless index(context).any?

    klass = scoping_class(field_def, relation, context)
    klass ? narrowed(klass, relation, context) : relation
  end

  def narrowed(klass, relation, context)
    scoped = klass.scope_items(relation, context)
    return scoped if scoped.respond_to?(:where)

    raise Lighthouse::DefinitionError,
          "#{klass}.scope_items must answer a relation for Lighthouse to query (got #{scoped.class}): it gets one, " \
          '`posts.where(...)`, a policy scope, ...'
  end

  # The records a field loaded (one, a list, or nil), less the ones the
  # scope_items of the type each resolves as leaves out (VisibleRecords.filter).
  def visible(value, field_def, context)
    Lighthouse::GraphQL::DataloaderSources::VisibleRecords.filter(value, field_def, context)
  end

  # `relation` narrowed by the scope_items of its model's type (a count of a
  # relation, @withCount).
  def scope_model(relation, context)
    klass = index(context).any? && relation.respond_to?(:klass) && model_scoping_class(nil, relation.klass, context)
    klass ? narrowed(klass, relation, context) : relation
  end

  # `relation` narrowed by the scope_items of the object type `type`, or of
  # its model's type when `type` is an entity interface (Federation::Entities).
  def scope_type(relation, type, context)
    return relation unless index(context).any?

    klass = type.kind.object? ? object_scoping_class(type.graphql_name, context) : model_scoping_class(nil, relation.klass, context)
    klass ? narrowed(klass, relation, context) : relation
  end

  # The Lighthouse class of the SDL type `name` (Lighthouse::GraphQL::Type),
  # looked up once per query, so code reloading takes a new class.
  def type_class(name, context)
    memo = memo(context)
    return memo[name] if memo&.key?(name)

    klass = Lighthouse::GraphQL::Type.class_for(name, :object)
    memo ? (memo[name] = klass) : klass
  end

  # The class whose scope_items applies to `relation`, or nil. A field that
  # returns records of an object type (or a page of them) scopes by that type
  # alone; one that returns an interface or a union, or no records (a count,
  # an aggregate), by the type of the relation's model.
  def scoping_class(field_def, relation, context)
    kind, name = records_of(field_def, context)
    return object_scoping_class(name, context) if kind == :object

    model_scoping_class(field_def, relation.klass, context) if relation.respond_to?(:klass)
  end

  # [:object, name] when a field's records are of an object type, [:abstract,
  # name] of an interface or a union (either, a page of them), nil when it
  # returns none. Read once per field and query.
  def records_of(field_def, context)
    return unless field_def.respond_to?(:type)

    memo = memo(context)
    return memo[field_def] if memo&.key?(field_def)

    records = read_records_of(field_def, context)
    memo ? (memo[field_def] = records) : records
  end

  def read_records_of(field_def, context)
    named = field_def.type.unwrap
    name = named.graphql_name.sub(Lighthouse::Support::ModelResolver::PAGINATION_SUFFIX, '')
    return [:abstract, name] if index(context).abstract?(name)

    [:object, name] if named.kind.object?
  end

  def object_scoping_class(name, context)
    type_class(name, context) if index(context).scoped?(name)
  end

  # The one type of `model` (or of its base class) whose class defines
  # scope_items. Two that do make the lookup ambiguous: an error, never an
  # unscoped answer.
  def model_scoping_class(field_def, model, context)
    names = scoped_names_of(model, context)
    return type_class(names.first, context) if names.size == 1
    return if names.empty?

    raise Lighthouse::DefinitionError,
          "#{field_def.respond_to?(:path) ? field_def.path : 'A lookup'} reads #{model.name}, which #{names.join(' and ')} " \
          'both scope (scope_items): say which with the field returning that type'
  end

  # The scoping types of `model`, else of its base class (an STI subclass's).
  def scoped_names_of(model, context)
    models = model.respond_to?(:base_class) ? [model, model.base_class].uniq : [model]
    models.map { |klass| index(context).scoped_of(klass.name) }.find(&:any?) || []
  end

  # The schema's Index; an empty one outside a query or for a schema Lighthouse did not build.
  def index(context)
    schema = context.respond_to?(:schema) ? context.schema : nil
    schema.respond_to?(:lighthouse_type_authorization) ? schema.lighthouse_type_authorization : Index::EMPTY
  end

  def memo(context)
    context.namespace(MEMO) if context.respond_to?(:namespace)
  end
end
