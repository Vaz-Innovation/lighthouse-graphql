# frozen_string_literal: true

# The SDL of the directives no registered resolver class contributes, and of
# the types they refer to: the field-level query directives (@builder,
# @whereAuth), the argument directives, the type-system ones (@union, @node,
# @model, ...), and those the schema reads while it is built. The registry
# injects each into a schema that uses it without declaring it.
module Lighthouse::GraphQL::Directives::Definitions
  # Directives that only mark the SDL for others to read.
  PASSIVE = {
    'nest' => <<~GRAPHQL.chomp,
      """
      Accepted on an argument or input field of an input object type, as PHP Lighthouse's SDL
      writes it. The filters of input fields (@eq, @where, ...) apply at any depth without it.
      """
      directive @nest on ARGUMENT_DEFINITION | INPUT_FIELD_DEFINITION
    GRAPHQL
    'spread' => <<~GRAPHQL.chomp,
      """
      On an argument of an input object type, merge the input's fields into the arguments
      the field's resolver or mutation receives, as if they were the field's own.
      """
      directive @spread on ARGUMENT_DEFINITION | INPUT_FIELD_DEFINITION
    GRAPHQL
    'inject' => <<~GRAPHQL.chomp,
      """
      Set an argument from the request's context, on the server, so clients cannot set it.
      """
      directive @inject(
        "A path in the context, with dots: \\"current_user.id\\"."
        context: String!
        "The name of the argument to set, with dots for a nested one: \\"input.author_id\\"."
        name: String!
      ) repeatable on FIELD_DEFINITION
    GRAPHQL
    'cacheKey' => <<~GRAPHQL.chomp
      """
      Mark the field whose value identifies its object in the keys of @cache and @clearCache.
      Without one, the first field of type ID is used.
      """
      directive @cacheKey on FIELD_DEFINITION
    GRAPHQL
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
    {
      'hasManyThrough' => [resolvers::HasManyDirectiveResolver, <<~TEXT.chomp],
        Resolve a one-to-many association of the parent that goes through another (`has_many :through`)
        as a list, batch-loaded so that listing it for many parents is not an N+1.
        With `type`, the list is paginated.
      TEXT
      'hasOneThrough' => [resolvers::HasOneDirectiveResolver, <<~TEXT.chomp]
        Resolve a one-to-one association of the parent that goes through another (`has_one :through`),
        batch-loaded so that loading it for many parents is not an N+1.
      TEXT
    }.to_h { |name, (klass, description)| [name, klass.definition(name, description)] }
  end

  # { type name => its SDL }, for the types the directives above refer to.
  def types
    graphql = Lighthouse::GraphQL
    [graphql::CacheControl::TYPE_DEFINITIONS, graphql::FeatureDirective::TYPE_DEFINITIONS, graphql::EnumDirective::TYPE_DEFINITIONS,
     graphql::DirectiveResolvers::BuilderApplier::TYPE_DEFINITIONS].reduce(:merge)
  end
end
