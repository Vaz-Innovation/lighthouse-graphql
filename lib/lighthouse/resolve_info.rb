# frozen_string_literal: true

# What PHP Lighthouse hands a resolver as its fourth argument, `$resolveInfo`:
# the field being resolved, where, with what, what the client selects below it
# (`lookahead`), and `enhance_builder`, which applies the field's own query
# directives to a query the resolver builds.
#
#   type Query {
#     posts(title: String @eq, orderBy: [PostOrderByClause!] @orderBy): [Post!]! @builder(class: "Published")
#   }
#
#   class Resolvers::Posts < Resolvers::BaseResolver
#     def resolve(**)
#       resolve_info.enhance_builder(Post.where(author: context[:current_user]), scopes: [:recent])
#     end
#   end
#
# A Resolvers:: / Mutations:: class, a class @field names and a type class's
# methods read it as `resolve_info`; a plain callable gets it as a fourth
# argument when it takes one: `call(object, args, context, resolve_info)`.
class Lighthouse::GraphQL::ResolveInfo
  LOOKAHEAD = :lighthouse_lookahead

  attr_reader :field, :parent_type, :object, :arguments, :context

  # graphql-ruby's GraphQL::Execution::Lookahead for the field: what the client
  # selects below it, to load only that (`lookahead.selects?(:author)`,
  # `lookahead.selection(:comments).arguments`). nil outside a query.
  attr_reader :lookahead

  # A field resolved by a class asks graphql-ruby for its lookahead.
  def self.request_lookahead(field_def)
    field_def.extras([:lookahead]) unless field_def.extras.include?(:lookahead)
  end

  def initialize(field:, parent_type:, object:, arguments:, context:)
    @field = field
    @parent_type = parent_type
    @object = object
    @arguments = arguments
    @context = context
    @lookahead = context.respond_to?(:[]) ? context[LOOKAHEAD] : nil
  end

  def field_name = field.graphql_name

  def return_type = field.type

  # The path from the root to this field, as graphql-ruby tracks it: ["posts", 0, "author"].
  def path
    context.respond_to?(:[]) ? context[:current_path] : nil
  end

  # `relation` with the field's model `scopes`, its @builder classes, and the
  # argument directives the client used (@eq, @where, @in, @like, @orderBy,
  # @whereConditions, @trashed, ...), as @all / @paginate apply them.
  def enhance_builder(relation, scopes: [])
    resolver = Lighthouse::GraphQL::DirectiveResolvers::BaseDirectiveResolver.new(field, parent_type, nil)
    args = arguments.respond_to?(:to_h) ? arguments.to_h : {}
    relation = Array(scopes).reduce(relation) { |acc, scope| acc.public_send(scope) }
    relation = Lighthouse::GraphQL::DirectiveResolvers::BuilderApplier.apply(relation, field.ast_node, args, context, resolver)
    resolver.apply_where_filters(relation, args, context)
  end

  # `resolve_info`, for the classes that resolve a field.
  module Accessor
    def resolve_info = @lighthouse_resolve_info
  end

  # Hand `info` to `resolver` (a GraphQL::Schema::Resolver or type class instance).
  def self.for(field_def, parent_type, object, arguments, context)
    new(field: field_def, parent_type: parent_type, object: object, arguments: arguments, context: context)
  end

  def self.attach(resolver, info)
    resolver.extend(Accessor) unless resolver.respond_to?(:resolve_info)
    resolver.instance_variable_set(:@lighthouse_resolve_info, info)
    resolver
  end
end
