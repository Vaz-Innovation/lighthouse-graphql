# frozen_string_literal: true

# Install a field's resolvers innermost first (see
# DirectiveRegistry#resolution_order), so each wrapper decorates the ones
# before it. Besides its directives, a field gets the conventional
# Resolvers::/Mutations:: resolver when it is a root field with no resolving
# directive, the method of the type's class (Types::PostType) when another
# type's field has none, and argument validation when an input type it takes
# carries @validator. The registry replaces a hardcoded `case dnode.name`: adding a
# directive is "register a class", not "edit the generator".
module Lighthouse::GraphQL::FieldResolverStack
  module_function

  # `bases`: { root kind => base class } from the schema's base_types (ResolverBases).
  # `type_class`: the class of a non-root type (Types::PostType), whose methods
  # resolve its fields that have no resolving directive.
  def apply(type, field_def, root_kind, bases: {}, type_class: nil)
    directives = field_def.ast_node.directives || []
    Lighthouse::Search::FieldCheck.check!(type, field_def, directives, root_kind, type_class: type_class)
    opts = { root_kind: root_kind, bases: bases }
    steps = directive_steps(type, field_def, directives, opts)
    steps << limit_step(type, field_def, opts) if Lighthouse::GraphQL::DirectiveResolvers::LimitResolver.keyword(field_def)
    steps << own_step(type, field_def, root_kind, bases, type_class) unless resolving_directive?(directives)
    steps << validator_step(type, field_def, opts) if input_validation?(field_def, directives)
    steps.concat(argument_steps(type, field_def, directives, opts))
    steps.concat(argument_authorization_steps(type, field_def, opts))

    steps.compact.each_with_index.sort_by { |(order, _), index| [order, index] }.each { |(_, step), _| step.call }
  end

  # [order, step] for every directive the registry has a resolver for.
  def directive_steps(type, field_def, directives, opts)
    registry = Lighthouse::DirectiveRegistry.default
    directives.filter_map do |dnode|
      resolver_class = registry.resolution_class(dnode.name)
      next unless resolver_class

      [registry.resolution_order(dnode.name), -> { resolver_class.new(field_def, type, dnode, opts).define_resolver(type) }]
    end
  end

  # The directive that resolves the field itself (a wrapper only decorates
  # another resolver), or nil: then the field needs a conventional one.
  def resolving_directive(directives)
    registry = Lighthouse::DirectiveRegistry.default
    directives.find { |d| registry.resolution_class(d.name) && !registry.wrapper?(d.name) }
  end

  def resolving_directive?(directives) = !resolving_directive(directives).nil?

  # Does the app's own code resolve a field with no resolving directive (own_step):
  # the conventional class of a root Query or Mutation field, or a method of the
  # type's class? Otherwise graphql-ruby's default reader reads it off the parent.
  def own_resolver?(field_def, root_kind, type_class)
    return true if %i[queries mutations].include?(root_kind)

    !!(type_class && Lighthouse::GraphQL::DirectiveResolvers::TypeMethodResolver.method_for(type_class, field_def))
  end

  def convention_step(type, field_def, root_kind, bases = {})
    resolvers = Lighthouse::GraphQL::DirectiveResolvers
    resolver =
      if root_kind == :subscriptions
        resolvers::SubscriptionDirectiveResolver.new(field_def, type, nil, root_kind: root_kind, bases: bases)
      else
        resolvers::ConventionResolver.new(field_def, type, root_kind, bases[root_kind])
      end
    [0, -> { resolver.define_resolver(type) }]
  end

  # What resolves a field with no resolving directive: the method of the
  # type's class (Types::QueryType#latest_posts too, as in graphql-ruby), else
  # for a Query or Mutation field the conventional class. nil: the default reader.
  def own_step(type, field_def, root_kind, bases, type_class)
    return convention_step(type, field_def, root_kind, bases) if root_kind == :subscriptions

    step = type_method_step(type, field_def, type_class, root: !root_kind.nil?) if type_class
    step || (convention_step(type, field_def, root_kind, bases) if root_kind)
  end

  # Nothing to install when the class does not define the field's method: the
  # field is read off the object.
  # `root`: the class is the root type's, which the type is built on, not one found by name.
  def type_method_step(type, field_def, type_class, root: false)
    resolver = Lighthouse::GraphQL::DirectiveResolvers::TypeMethodResolver
    method_name = resolver.method_for(type_class, field_def)
    [0, -> { resolver.new(field_def, type, method_name, root ? type_class : nil).define_resolver(type) }] if method_name
  end

  # An explicit @validator on the field already validates its arguments.
  def input_validation?(field_def, directives)
    directives.none? { |d| d.name == 'validator' } &&
      Lighthouse::GraphQL::DirectiveResolvers::ValidatorDirectiveResolver.input_validators?(field_def)
  end

  def validator_step(type, field_def, opts)
    resolver = Lighthouse::GraphQL::DirectiveResolvers::ValidatorDirectiveResolver
    [Lighthouse::DirectiveRegistry.default.resolution_order('validator'),
     -> { resolver.new(field_def, type, nil, opts).define_resolver(type) }]
  end

  # Without @convertEmptyStringsToNull on the field itself, an argument or input
  # type that carries it (or Config.convert_empty_strings_to_null) still converts.
  def empty_string_conversion?(field_def, directives)
    directives.none? { |d| d.name == 'convertEmptyStringsToNull' } &&
      Lighthouse::GraphQL::DirectiveResolvers::ConvertEmptyStringsToNullDirectiveResolver.implicit?(field_def)
  end

  # The steps that change the arguments: empty strings to null and the rewriting
  # directives (@globalId, @trim, @drop) outermost, so every wrapper sees them;
  # the effectful ones (@hash, @bind, @upload) once @guard, @can* and @validator
  # have let the call through (ArgumentTransformsResolver).
  ARGUMENT_PHASES = { rewrite: 'convertEmptyStringsToNull', effects: 'cache' }.freeze

  def argument_steps(type, field_def, directives, opts)
    steps = []
    steps << empty_strings_step(type, field_def, opts) if empty_string_conversion?(field_def, directives)
    ARGUMENT_PHASES.each do |phase, alongside|
      next unless Lighthouse::GraphQL::DirectiveResolvers::ArgumentTransformsResolver.transforms?(field_def, phase)

      steps << transforms_step(type, field_def, opts.merge(phase: phase), Lighthouse::DirectiveRegistry.default.resolution_order(alongside))
    end
    steps
  end

  # A @canModel on an argument or input field, at any depth: who may use it.
  # Ordered with the field's @can* directives; it checks only when the client
  # gave the argument a value (CanModelDirectiveResolver).
  def argument_authorization_steps(type, field_def, opts)
    resolver = Lighthouse::GraphQL::DirectiveResolvers::CanModelDirectiveResolver
    order = Lighthouse::DirectiveRegistry.default.resolution_order(resolver.directive_name)
    authorized_arguments(field_def.arguments).map do |path, dnode|
      [order, -> { resolver.new(field_def, type, dnode, opts.merge(argument: path)).define_resolver(type) }]
    end
  end

  # [dot path ("filter.trashed", "inputs.*.status"), @canModel node] for every
  # argument and input field carrying @canModel (Support::ArgumentWalk).
  def authorized_arguments(arguments)
    walk = Lighthouse::Support::ArgumentWalk
    walk.definitions(arguments).flat_map do |path, argument|
      walk.directives(argument).select { |d| d.name == 'canModel' }.map { |dnode| [path, dnode] }
    end
  end

  # Around whatever resolves the field, as @lazyLoad: the result is cut to the client's @limit.
  def limit_step(type, field_def, opts)
    [1, -> { Lighthouse::GraphQL::DirectiveResolvers::LimitResolver.new(field_def, type, nil, opts).define_resolver(type) }]
  end

  def transforms_step(type, field_def, opts, order)
    [order, -> { Lighthouse::GraphQL::DirectiveResolvers::ArgumentTransformsResolver.new(field_def, type, nil, opts).define_resolver(type) }]
  end

  def empty_strings_step(type, field_def, opts)
    resolver = Lighthouse::GraphQL::DirectiveResolvers::ConvertEmptyStringsToNullDirectiveResolver
    [Lighthouse::DirectiveRegistry.default.resolution_order(resolver.directive_name),
     -> { resolver.new(field_def, type, nil, opts).define_resolver(type) }]
  end
end
