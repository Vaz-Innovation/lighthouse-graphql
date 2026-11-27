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
# `authorized?` runs where graphql-ruby runs it: the SDL's object types hand it
# to their class. `scope_items` runs where Lighthouse builds a query for records
# of the type (BaseDirectiveResolver#apply_where_filters: @all, @paginate, @find,
# @first, @count, @aggregate, the relationship directives, enhance_builder), on
# the batched loads of a relationship (DataloaderSources::VisibleRecords, one
# query per batch), and on Federation's entity lookups. It gets a relation and
# must answer one. A query directive whose field returns no records (@count,
# @aggregate) is scoped by the type whose model it counts, when one type of that
# model defines scope_items.
module Lighthouse::GraphQL::TypeAuthorization
  MEMO = :lighthouse_type_authorization

  module_function

  # Each object type of the schema, but its root types (built on their classes
  # already, RootTypes), hands `authorized?` to its class.
  def apply(schema)
    roots = [schema.query, schema.mutation, schema.subscription].compact
    schema.types.each_value do |type|
      next unless type.kind.object? && !type.graphql_name.start_with?('__') && roots.exclude?(type)

      name = type.graphql_name
      type.define_singleton_method(:authorized?) do |object, context|
        klass = Lighthouse::GraphQL::TypeAuthorization.type_class(name, context)
        klass ? klass.authorized?(object, context) : super(object, context)
      end
    end
  end

  # `relation`, narrowed by the scope_items of the type its records resolve as:
  # the field's return type, else the one type of the relation's model that
  # defines it. A scope_items that answers no relation is the app's error.
  def scope(relation, field_def, context)
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

  # The records a relationship field loaded (one, a list, or nil), less the
  # ones its type's scope_items leaves out: one query per batch of them.
  def visible(value, field_def, context)
    klass = context && value && field_scoping_class(field_def, context)
    return value unless klass

    records = Array.wrap(value)
    kept = records.zip(shown(klass, records, context)).filter_map { |record, shown| record if shown }
    value.respond_to?(:to_ary) ? kept : kept.first
  end

  # `relation` narrowed by the scope_items of its model's type (a count of a
  # relation, @withCount).
  def scope_model(relation, context)
    klass = model_scoping_class(nil, relation, context)
    klass ? narrowed(klass, relation, context) : relation
  end

  # `relation` narrowed by the scope_items of the object type `type` (an entity
  # lookup, Federation::Entities).
  def scope_type(relation, type, context)
    return relation unless type.kind.object?

    klass = scoping(type_class(type.graphql_name, context))
    klass ? narrowed(klass, relation, context) : relation
  end

  # Whether each record is one its type's scope_items keeps: batched with the
  # other parents' through the Dataloader, at once without one.
  def shown(klass, records, context)
    dataloader = Lighthouse::Support::Batching.dataloader(context)
    source = Lighthouse::GraphQL::DataloaderSources::VisibleRecords
    return source.new(klass, context).fetch(records) unless dataloader

    dataloader.with(source, klass, context).load_all(records)
  end

  # The Lighthouse class of the SDL type `name` (Lighthouse::GraphQL::Type),
  # looked up once per query, so code reloading takes a new class.
  def type_class(name, context)
    memo = memo(context)
    return memo[name] if memo&.key?(name)

    klass = Lighthouse::GraphQL::Type.class_for(name, :object)
    memo ? (memo[name] = klass) : klass
  end

  # The class whose scope_items applies to `relation`, or nil.
  # A field that returns records of a type scopes by that type alone; one that
  # returns none (a count, an aggregate) by its model's.
  def scoping_class(field_def, relation, context)
    return field_scoping_class(field_def, context) if records_type?(field_def)

    model_scoping_class(field_def, relation, context)
  end

  def records_type?(field_def)
    field_def.respond_to?(:type) && field_def.type.unwrap.kind.object?
  end

  def field_scoping_class(field_def, context)
    return unless records_type?(field_def)

    scoping(type_class(field_def.type.unwrap.graphql_name.sub(Lighthouse::Support::ModelResolver::PAGINATION_SUFFIX, ''), context))
  end

  # For a field that answers no records of a type (a count, an aggregate): the
  # one type of the relation's model whose class defines scope_items. Two that
  # do make the field's count ambiguous: an error, never an unscoped answer.
  def model_scoping_class(field_def, relation, context)
    return unless context.respond_to?(:schema) && relation.respond_to?(:klass)

    model = relation.klass.name
    classes = model_scoping_classes(model, context)
    return classes.first if classes.size <= 1

    raise Lighthouse::DefinitionError,
          "#{field_def.respond_to?(:path) ? field_def.path : 'A count'} counts #{model}, which #{classes.join(' and ')} " \
          'both scope (scope_items): say which with the field returning that type'
  end

  # The classes defining scope_items of the object types whose model is `model`.
  def model_scoping_classes(model, context)
    context.schema.types.each_value.filter_map do |type|
      next unless type.kind.object? && Lighthouse::GraphQL::Directives::ModelDirective.model_for(type)&.name == model

      scoping(type_class(type.graphql_name, context))
    end.uniq
  end

  # `klass` when it defines scope_items of its own (or its base does), else nil.
  def scoping(klass)
    klass if klass.respond_to?(:scope_items) && klass.method(:scope_items).owner != ::GraphQL::Schema::Member::Scoped
  end

  def memo(context)
    context.namespace(MEMO) if context.respond_to?(:namespace)
  end
end
