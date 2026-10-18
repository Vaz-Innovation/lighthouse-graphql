# frozen_string_literal: true

# Calls the class a field resolves to. Classes in the queries and mutations
# namespaces follow graphql-ruby's contract — GraphQL::Schema::Resolver and
# GraphQL::Schema::Mutation: `resolve(**args)` with `object` and `context`,
# plus `ready?` / `authorized?` — exactly as in a graphql-ruby schema.
# @field also accepts a plain callable, `call(object, args, context)`, which
# gets the ResolveInfo as a fourth argument when it takes one.
#
# `method:` is the method after `@` in `@field(resolver: "Class@method")`: it
# replaces `resolve` (keeping `ready?` / `authorized?`) on a resolver class, and
# `call` on a plain class, as a class method or else an instance method.
module Lighthouse::GraphQL::ResolverDispatch
  module_function

  def graphql_resolver?(klass)
    klass.is_a?(Class) && klass < ::GraphQL::Schema::Resolver
  end

  # `info`: the ResolveInfo of the field being resolved, which carries its
  # object, arguments and context.
  def call(klass, info, method: nil)
    return call_resolver(klass, info, method) if graphql_resolver?(klass)

    receiver = callable_receiver(klass, method || :call)
    callable = receiver.method(method || (receiver.respond_to?(:call) ? :call : :resolve))
    args = [info.object, info.arguments, info.context]
    takes_info?(receiver, callable) ? callable.call(*args, info) : callable.call(*args)
  end

  def call_resolver(klass, info, method)
    kwargs = Lighthouse::Support::Arguments.prepare(info.field, info.arguments, info.context)
    instance = Lighthouse::GraphQL::ResolveInfo.attach(klass.new(object: info.object, context: info.context, field: info.field), info)
    instance.define_singleton_method(:resolve) { |**values| public_send(method, **values) } if method
    single_input?(instance, kwargs) ? instance.resolve_with_support(**kwargs) : resolve_as_mutation(instance, kwargs)
  end

  # graphql-ruby's RelayClassicMutation (the base mutation its install writes)
  # takes one `input:` argument. A field that declares its arguments one by one
  # calls it as a plain GraphQL::Schema::Mutation, with them as keywords: past
  # HasSingleInputArgument's unwrapping of `input:`, and its authorization of
  # the arguments of `input:`.
  def single_input?(instance, kwargs)
    !instance.is_a?(::GraphQL::Schema::HasSingleInputArgument) || kwargs.key?(:input)
  end

  def resolve_as_mutation(instance, kwargs)
    instance.define_singleton_method(:authorize_arguments, ::GraphQL::Schema::Resolver.instance_method(:authorize_arguments))
    instance.singleton_class.send(:private, :authorize_arguments)
    ::GraphQL::Schema::Mutation.instance_method(:resolve_with_support).bind_call(instance, **kwargs)
  end

  # The class itself when it answers `name` as a class method, else an instance.
  def callable_receiver(klass, name)
    klass.respond_to?(name) ? klass : klass.new
  end

  POSITIONAL = %i[req opt].freeze

  # Does the callable take a fourth argument? A lambda's own parameters count,
  # not Proc#call's (*args).
  def takes_info?(receiver, callable)
    params = receiver.is_a?(Proc) && callable.name == :call ? receiver.parameters : callable.parameters
    params.any? { |type, _| type == :rest } || params.count { |type, _| POSITIONAL.include?(type) } >= 4
  end
end
