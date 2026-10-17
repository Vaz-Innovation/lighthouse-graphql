# frozen_string_literal: true

# Install a field's resolvers innermost first (see
# DirectiveRegistry#resolution_order), so each wrapper decorates the ones
# before it. Besides its directives, a field gets the conventional
# Queries::/Mutations:: resolver when it is a root field with no resolving
# directive, and argument validation when an input type it takes carries
# @validator. The registry replaces a hardcoded `case dnode.name`: adding a
# directive is "register a class", not "edit the generator".
module Lighthouse::GraphQL::FieldResolverStack
  module_function

  def apply(type, field_def, directives, root_kind)
    opts = { root_kind: root_kind }
    steps = directive_steps(type, field_def, directives, opts)
    steps << convention_step(type, field_def, root_kind) if root_kind && !resolving_directive?(directives)
    steps << validator_step(type, field_def, opts) if input_validation?(field_def, directives)

    steps.each_with_index.sort_by { |(order, _), index| [order, index] }.each { |(_, step), _| step.call }
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

  def convention_step(type, field_def, root_kind)
    resolver = Lighthouse::GraphQL::DirectiveResolvers::ConventionResolver
    [0, -> { resolver.new(field_def, type, root_kind).define_resolver(type) }]
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
end
