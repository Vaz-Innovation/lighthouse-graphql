# frozen_string_literal: true

module Lighthouse::GraphQL
  # graphql-ruby (2.5/2.6) hands a directive application's `null` literal —
  # `@paginate(maxCount: null)` — to the directive as a NullValue node instead
  # of nil, and building the schema then fails to coerce it. Its own
  # build_default_value already maps NullValue to nil; do the same here.
  module NullDirectiveArguments
    def args_to_kwargs(arg_owner, node)
      node.is_a?(::GraphQL::Language::Nodes::NullValue) ? nil : super
    end
  end

  # The builder is a private constant; if a graphql-ruby release reshapes it,
  # skip the fix rather than fail to load (explicit nulls then fail as before).
  builder = ::GraphQL::Schema::BuildFromDefinition.const_get(:Builder) if ::GraphQL::Schema::BuildFromDefinition.const_defined?(:Builder)
  builder.prepend(NullDirectiveArguments) if builder && (builder.method_defined?(:args_to_kwargs) || builder.private_method_defined?(:args_to_kwargs))

  # graphql-ruby builds every SDL object type on base_types[:object], and every
  # interface from base_types[:interface]. RootTypes builds a root type on the
  # app's code-first one (Types::QueryType) instead, and takes the app's Node
  # interface (Types::NodeType) as the SDL's Node.
  module RootTypeBuilder
    def build_object_type(definition, type_resolver, base_type)
      root = Lighthouse::GraphQL::RootTypes.base_for(definition.name)
      return super unless root

      super(Lighthouse::GraphQL::RootTypes.definition_on(definition, root), type_resolver, root)
    end

    def build_interface_type(definition, type_resolver, base_type)
      Lighthouse::GraphQL::RootTypes.base_for(definition.name) || super
    end
  end

  # As above, a graphql-ruby release that reshapes the builder skips the hook:
  # root types are then built on base_types[:object], as before.
  if builder && %i[build_object_type build_interface_type].all? { |name| builder.method_defined?(name) || builder.private_method_defined?(name) }
    builder.prepend(RootTypeBuilder)
  end

  # The app's schema class inherits Lighthouse's (`class AppSchema <
  # get_schema(...)`), so its Subscription root type is the parent's. A
  # subscriptions backend the subclass `use`s (ActionCableSubscriptions) then
  # finds no root type of the subclass's own, and graphql-ruby adds its
  # subscription extension to no field. Look the root type up through the
  # parent too. Extended onto the schemas Lighthouse builds (SchemaGenerator).
  module InheritedSubscriptionRoot
    def add_subscription_extension_if_necessary
      return super if @subscription_object.is_a?(Class) || !defined?(::GraphQL::Subscriptions::DefaultSubscriptionResolveExtension)
      return unless inherited_subscription_root_pending?

      @subscription_extension_added = true
      extension = ::GraphQL::Subscriptions::DefaultSubscriptionResolveExtension
      subscription.all_field_definitions.each { |field| field.extension(extension) unless field.extensions.any?(extension) }
    end

    # A backend, a root type from the parent, and no extension added yet.
    def inherited_subscription_root_pending?
      !defined?(@subscription_extension_added) && subscription.is_a?(Class) && !subscriptions.nil?
    end
  end
end
