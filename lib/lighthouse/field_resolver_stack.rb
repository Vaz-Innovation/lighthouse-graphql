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
    opts = { root_kind: root_kind, bases: bases }
    steps = directive_steps(type, field_def, directives, opts)
    steps << limit_step(type, field_def, opts) if Lighthouse::GraphQL::DirectiveResolvers::LimitResolver.keyword(field_def)
    steps << own_step(type, field_def, root_kind, bases, type_class) unless resolving_directive?(directives)
    steps << validator_step(type, field_def, opts) if input_validation?(field_def, directives)
    steps.concat(argument_steps(type, field_def, directives, opts))

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

  # Whether a directive resolves the field itself (a wrapper only decorates
  # another resolver), so the field needs no conventional one.
  def resolving_directive?(directives)
    registry = Lighthouse::DirectiveRegistry.default
    directives.any? { |d| registry.resolution_class(d.name) && !registry.wrapper?(d.name) }
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
