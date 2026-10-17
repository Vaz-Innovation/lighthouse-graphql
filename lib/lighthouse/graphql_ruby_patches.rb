# frozen_string_literal: true

module Lighthouse
  module GraphQL
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
    if builder && (builder.method_defined?(:args_to_kwargs) || builder.private_method_defined?(:args_to_kwargs))
      builder.prepend(NullDirectiveArguments)
    end
  end
end
