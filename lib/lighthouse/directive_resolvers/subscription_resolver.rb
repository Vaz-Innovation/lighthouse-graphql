# frozen_string_literal: true

require_relative 'base'

# Resolves a field of the Subscription root type, with @subscription(class:)
# or, without the directive, by convention: `Subscription.postUpdated`
# resolves to `Subscriptions::PostUpdated`, looked up in
# Config.namespaces[:subscriptions] at call time so code reloading keeps
# working. The class is a GraphQL::Schema::Subscription (see
# Lighthouse::GraphQL::Subscription for PHP Lighthouse's hooks). A field
# with no class still works: it is a Lighthouse::GraphQL::Subscription whose
# update is the broadcast root, which is all `@broadcast` needs.
#
# graphql-ruby registers a subscription through the class its field was
# built from, which a field built from SDL has not. The field is therefore
# told which class it stands for: its `resolver` (read by graphql-ruby to build
# the topic, and to know the subscription instance wrote itself) and its
# `subscription_scope` answer for the class. The class is instantiated for
# each request, so its hooks (`subscribe`, `update`, ...) run as usual.
class Lighthouse::GraphQL::DirectiveResolvers::SubscriptionDirectiveResolver < Lighthouse::GraphQL::DirectiveResolvers::BaseDirectiveResolver
  def self.directive_name = 'subscription'
  def self.definition = 'directive @subscription(class: String!) on FIELD_DEFINITION'

  def define_resolver(target_type_class)
    unless @opts[:root_kind] == :subscriptions
      raise Lighthouse::DefinitionError, "@subscription is for fields of the Subscription type, not #{location}."
    end

    me = self
    @field_def.define_singleton_method(:resolver) { me.subscription_class }
    @field_def.define_singleton_method(:subscription_scope) { me.subscription_class.subscription_scope }

    install(target_type_class, lambda do |obj, args, ctx|
      Lighthouse::GraphQL::ResolverDispatch.call(me.subscription_class, me.field_def, obj, args, ctx)
    end)
  end

  attr_reader :field_def

  # The class this field stands for: the one @subscription names, else the
  # conventional one, else the default.
  def subscription_class
    klass = find_class
    return Lighthouse::GraphQL::Subscription unless klass

    unless klass.is_a?(Class) && klass < ::GraphQL::Schema::Subscription
      raise Lighthouse::DefinitionError, "#{klass} resolves #{location}, so it must inherit from GraphQL::Schema::Subscription " \
                                         '(or Lighthouse::GraphQL::Subscription).'
    end

    klass
  end

  private

  def find_class
    namespaces = Lighthouse::Config.namespaces[:subscriptions]
    named = directive_arg('class') if @directive_node
    klass = Lighthouse::Support::ModelResolver.constantize(named || @field_def.name.to_s.camelize, namespaces: namespaces, fallback: false)
    return klass if klass || named.nil?

    expected = Array(namespaces).map { |ns| "#{ns}::#{named}" }.join(' or ')
    raise Lighthouse::DefinitionError, "@subscription(class: #{named.inspect}) on #{location}: no such class (looked for #{expected})."
  end

  def location
    "#{@type_def.graphql_name}.#{@field_def.name}"
  end
end
