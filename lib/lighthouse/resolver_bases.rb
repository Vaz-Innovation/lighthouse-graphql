# frozen_string_literal: true

# The base classes of the classes root fields resolve to, given to `get_schema`
# beside graphql-ruby's own base types:
#
#   Lighthouse::GraphQL::RbLightHouse.get_schema(options: { base_types: {
#     resolver: Resolvers::BaseResolver, mutation: Mutations::BaseMutation,
#     subscription: Subscriptions::BaseSubscription, object: Types::BaseObject
#   } })
#
# graphql-ruby's `from_definition` knows only the SDL's own kinds (object,
# interface, union, scalar, enum, input_object), so these three are taken out
# before it sees the rest. Each one given:
#
# - is the class every class of its kind must inherit from: a Query, Mutation or
#   Subscription field's class, found by convention or through
#   @subscription(class:), that does not raises Lighthouse::DefinitionError when
#   it is first used, so none misses what the base shares;
# - for subscriptions, also resolves a Subscription field that has no class of
#   its own, instead of Lighthouse::GraphQL::Subscription::Default.
module Lighthouse::GraphQL::ResolverBases
  # base_types key => the graphql-ruby class the base must inherit from.
  GRAPHQL_CLASSES = {
    resolver: ::GraphQL::Schema::Resolver,
    mutation: ::GraphQL::Schema::Mutation,
    subscription: ::GraphQL::Schema::Subscription
  }.freeze

  # Root kind => base_types key.
  KEYS = { queries: :resolver, mutations: :mutation, subscriptions: :subscription }.freeze

  module_function

  # graphql-ruby's base types that the type classes of the same kind
  # (Types::PostType, Types::DateTimeType, ...) inherit from too.
  TYPE_KINDS = %i[object union interface scalar].freeze

  # Take the three keys out of opts[:base_types] (the caller's Hash is not
  # changed) and return { root kind => base class } for those given, plus
  # :types => { kind => base } for graphql-ruby's own, which stay in opts.
  def extract!(opts)
    base_types = opts[:base_types]
    return {} unless base_types.is_a?(Hash)

    given = base_types.slice(*GRAPHQL_CLASSES.keys).compact
    opts[:base_types] = base_types.except(*GRAPHQL_CLASSES.keys)
    given.each { |key, klass| validate!(key, klass) }
    bases = KEYS.filter_map { |kind, key| [kind, given[key]] if given[key] }.to_h
    type_bases = base_types.slice(*TYPE_KINDS).compact
    type_bases.empty? ? bases : bases.merge(types: type_bases)
  end

  def validate!(key, klass)
    expected = GRAPHQL_CLASSES.fetch(key)
    return if klass.is_a?(Class) && klass < expected

    raise Lighthouse::DefinitionError, "base_types[:#{key}] must be a subclass of #{expected}, not #{klass.inspect}."
  end

  # Raise unless `klass`, which resolves the field at `location`, inherits from
  # `base` (nil: no base was given).
  def check!(klass, base, location)
    return if base.nil? || klass <= base

    raise Lighthouse::DefinitionError,
          "#{klass} resolves #{location}, so it must inherit from #{base}, the schema's base class for it (base_types)."
  end
end
