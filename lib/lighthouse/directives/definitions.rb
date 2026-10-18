# frozen_string_literal: true

# The SDL of the directives no registered resolver class contributes, and of
# the types they refer to: the field-level query directives (@builder,
# @whereAuth), the argument directives, the type-system ones (@union, @node,
# @model, ...), and those the schema reads while it is built. The registry
# injects each into a schema that uses it without declaring it.
module Lighthouse::GraphQL::Directives::Definitions
  # Directives that only mark the SDL for others to read.
  PASSIVE = {
    'nest' => 'directive @nest on ARGUMENT_DEFINITION | INPUT_FIELD_DEFINITION',
    'spread' => 'directive @spread on ARGUMENT_DEFINITION | INPUT_FIELD_DEFINITION',
    'inject' => 'directive @inject(context: String!, name: String!) repeatable on FIELD_DEFINITION',
    'cacheKey' => 'directive @cacheKey on FIELD_DEFINITION'
  }.freeze

  module_function

  # { name => "directive @name ..." }
  def directives
    graphql = Lighthouse::GraphQL
    [
      graphql::DirectiveResolvers::BuilderApplier::DEFINITIONS,
      graphql::DirectiveResolvers::ArgumentTransformsResolver::DEFINITIONS,
      PASSIVE,
      { 'cacheControl' => graphql::CacheControl::DEFINITION, 'feature' => graphql::FeatureDirective::DEFINITION,
        'complexity' => graphql::Complexity::DEFINITION, 'scalar' => graphql::ScalarCoercion::DEFINITION,
        'enum' => graphql::EnumDirective::DEFINITION },
      through_aliases,
      graphql::TypeResolution::DEFINITIONS,
      graphql::Directives::NodeDirective::DEFINITIONS,
      graphql::Directives::ModelDirective::DEFINITIONS,
      graphql::Directives::VisibilityDirective::DEFINITIONS,
      graphql::Directives::SoftDeletesDirective::DEFINITIONS
    ].reduce(:merge)
  end

  # @hasManyThrough and @hasOneThrough: @hasMany's and @hasOne's definitions, renamed.
  def through_aliases
    resolvers = Lighthouse::GraphQL::DirectiveResolvers
    { 'hasManyThrough' => resolvers::HasManyDirectiveResolver, 'hasOneThrough' => resolvers::HasOneDirectiveResolver }
      .to_h { |name, klass| [name, klass.definition.sub("@#{klass.directive_name}(", "@#{name}(")] }
  end

  # { type name => its SDL }, for the types the directives above refer to.
  def types
    graphql = Lighthouse::GraphQL
    [graphql::CacheControl::TYPE_DEFINITIONS, graphql::FeatureDirective::TYPE_DEFINITIONS, graphql::EnumDirective::TYPE_DEFINITIONS,
     graphql::DirectiveResolvers::BuilderApplier::TYPE_DEFINITIONS].reduce(:merge)
  end
end
