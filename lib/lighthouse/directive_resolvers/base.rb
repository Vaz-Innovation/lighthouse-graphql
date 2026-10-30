# frozen_string_literal: true

class Lighthouse::GraphQL::DirectiveResolvers::BaseDirectiveResolver
  # A directive argument's SDL with its description, indented to sit in a
  # definition's parentheses (see the constants below, and `definition`s).
  def self.argument_sdl(declaration, description)
    %(  "#{description.gsub(/["\\]/) { |c| "\\#{c}" }}"\n  #{declaration})
  end

  # The arguments many directives share, to splice into a definition with
  # `#{MODEL_ARGUMENT}`.
  MODEL_ARGUMENT = argument_sdl(
    'model: String',
    "The class name of the model to use. Defaults to the model of another directive on the field, else the field's return type."
  )
  SCOPES_ARGUMENT = argument_sdl('scopes: [String!]', 'Names of model scopes to apply to the underlying query, in order.')
  RELATION_ARGUMENT = argument_sdl(
    'relation: String',
    "The name of the association on the parent model. Defaults to the field's name in snake_case."
  )

  # Whether the resolver applies a @search on its field, as Contracts::FieldResolver
  # describes: the base resolver does not; a subclass that runs the field's
  # argument filters says so.
  extend Lighthouse::Contracts::FieldResolver::SearchDefaults

  def initialize(field_def, type_def, directive_node, opts = {})
    @field_def = field_def
    @type_def = type_def
    @directive_node = directive_node
    @opts = opts
  end

  def define_resolver(target_type_class)
    raise NotImplementedError
  end

  # What a caller can take from a search outside the database (Searchkick), which
  # answers with a Search::Result in place of a relation (`search:`):
  #
  #   nil      a relation only: such a search is a client error
  #   :model   a Search::Result, for the model's own relation the caller built (`Model.all`, `scopes:`)
  #   :given   a Search::Result, for a relation the app's code gave (enhance_builder), which the
  #            engine refuses unless it selects what the model's own does
  SEARCHES = [nil, :model, :given].freeze

  # `ctx`: the query's context, for @builder on an argument. `search`: SEARCHES.
  def apply_where_filters(relation, args, ctx = nil, search: nil)
    raise ArgumentError, "search: is nil, :model or :given, got #{search.inspect}" unless SEARCHES.include?(search)
    return relation unless relation.respond_to?(:where)

    relation = relation.all if relation.is_a?(Class) # a model class, as `enhance_builder(Post)` gives it
    args_h = args_hash(args)
    builders = arg_builders(args_h) if searching?
    searched = apply_search(relation, builders, ctx, search)
    return searched if searched.is_a?(Lighthouse::Search::Result)

    filtered = apply_query_filters(searched, args_h, ctx, builders)
    searched.equal?(relation) ? filtered : Lighthouse::GraphQL::Pagination.stable_order(filtered)
  end

  # Compose argument-builder directives (@eq, @neq, @in, @notIn, @like,
  # @where, @orderBy, @whereConditions, @whereHasConditions) onto the relation, in SDL argument order, for each
  # field argument that carries one and that the client supplied a value
  # for — and for the fields of the input objects the client sent, at any depth.
  def apply_arg_builders(relation, args_h, ctx = nil)
    return relation unless relation.respond_to?(:where)
    return relation unless @field_def.ast_node

    apply_builders(relation, arg_builders(args_h), ctx)
  end

  def constantize_model(name)
    Lighthouse::Support::ModelResolver.constantize(name)
  end

  # The model scopes the directive's `scopes:` argument names, in order.
  def apply_scopes(relation)
    Array(directive_arg('scopes')).reduce(relation) { |acc, scope| acc.public_send(scope) }
  end

  protected

  def directive_arg(name)
    Lighthouse::Support::DirectiveArgs.literal(@directive_node, name)
  end

  def resolver_method_name
    "resolve_field_#{@field_def.name}"
  end

  # The field's resolver so far, for a directive that wraps it.
  def capture_inner(target_type_class)
    Lighthouse::GraphQL::DirectiveResolvers::Resolution.capture(target_type_class, resolver_method_name, @field_def, @field_def.name)
  end

  def install(target_type_class, callable)
    target_type_class.define_singleton_method(resolver_method_name, &callable)
    @field_def.resolve_proc = callable if @field_def.respond_to?(:resolve_proc=)
  end

  # The model a directive acts on: its `model:` argument, the `model:` of
  # another directive on the field (`@count(model: "Post") @canQuery`), or
  # the field's return type without a generated Paginator/Connection suffix.
  def model_class
    name = Lighthouse::Support::ModelResolver.field_model_name(@field_def, @directive_node)
    constantize_model(name) || raise(Lighthouse::DefinitionError,
                                     "@#{@directive_node&.name} on #{@type_def.graphql_name}.#{@field_def.name}: no model #{name}")
  end

  private

  def args_hash(args) = args.respond_to?(:to_h) ? args.to_h : (args || {})

  # The field's arguments and own query directives, on the relation: what is left
  # after the search, if any. `builders`: the field's arg_builders, when the search walked them.
  def apply_query_filters(relation, args_h, ctx, builders = nil)
    filtered = builders ? apply_builders(relation, builders, ctx) : apply_arg_builders(relation, args_h, ctx)
    apply_field_builders(filtered, args_h, ctx)
  rescue ::GraphQL::ExecutionError
    raise
  rescue StandardError => e
    Lighthouse::Config.handle_error(e)
    relation
  end

  # The argument builders (arg_builders) on the relation, in order.
  def apply_builders(relation, builders, ctx)
    builders.each do |values, node, dnode, builder_class|
      relation = apply_arg_builder(relation, values, ctx, [[node.name], node, dnode, builder_class])
    end

    relation
  rescue ::GraphQL::ExecutionError
    raise
  rescue StandardError => e
    Lighthouse::Config.handle_error(e)
    relation
  end

  # The relation searched, when the client sent a string for an argument with @search
  # (Search::Enhancer), else the relation itself: its errors are the client's or
  # the schema's, never swallowed. A relational search's order ends with the primary
  # key once every other order applies (apply_where_filters), so the matches that
  # rank, and sort, alike come back in one order, whatever the field resolves with.
  # `builders`: the field's arg_builders, walked once for the search and the
  # filters after it; nil when the field has no @search.
  def apply_search(relation, builders, ctx, search)
    return relation unless builders

    arguments = builders.map do |values, node, dnode, builder_class|
      path = [node.name]
      Lighthouse::Search::Enhancer::Argument.new(node, dnode, builder_class, dig_arg(values, path), arg_present?(values, path))
    end
    Lighthouse::Search::Enhancer.new(arguments, relation, search: search, context: ctx).enhance
  end

  # Does the field have an argument or input field with @search? Known when the schema is built.
  def searching?
    @field_def.ast_node && Lighthouse::Search.searching?(@field_def)
  end

  # The field's own query directives (@builder, @whereAuth, @orderBy(column:)),
  # in SDL order, after the arguments', as PHP Lighthouse's enhanceBuilder applies them.
  def apply_field_builders(relation, args_h = {}, ctx = nil)
    Lighthouse::GraphQL::DirectiveResolvers::BuilderApplier.apply(relation, @field_def.ast_node, args_h, ctx, self)
  end

  # Every (argument, directive, builder class) on the field, in SDL order.
  # One argument directive: @builder whenever the client sent the argument,
  # null included (as PHP Lighthouse's); the others when its value is not null.
  def apply_arg_builder(relation, args_h, ctx, (path, arg_node, dnode, builder_class))
    if builder_class == :builder
      return relation unless arg_present?(args_h, path)

      return Lighthouse::GraphQL::DirectiveResolvers::BuilderApplier.apply_argument(relation, dnode, dig_arg(args_h, path), ctx)
    end

    value = dig_arg(args_h, path)
    value.nil? ? relation : builder_class.new(arg_node, dnode).handle_builder(relation, value)
  end

  # Did the client send the argument at `path`, even as null?
  def arg_present?(args_h, path)
    parent = path.size == 1 ? args_h : dig_arg(args_h, path[0...-1])
    hash = parent.respond_to?(:to_h) && !parent.is_a?(Array) ? parent.to_h : parent
    hash.is_a?(Hash) && Lighthouse::Support::Naming.candidate_keys(path.last).any? { |key| hash.key?(key) }
  end

  # Did the client send an argument or input field, at any depth, that
  # carries an argument-builder directive? As PHP Lighthouse's wouldEnhanceBuilder.
  # A @search argument narrows only when a search runs, for a string: null or
  # nothing leaves the query whole (PHP Lighthouse's ScoutEnhancer#wouldEnhanceBuilder).
  def filtering?(args_h)
    arg_builders(args_h).any? do |values, node, _dnode, builder_class|
      if builder_class == Lighthouse::GraphQL::Directives::Arguments::Search
        dig_arg(values, [node.name]).is_a?(String)
      else
        arg_present?(values, [node.name])
      end
    end
  end

  # [values, node, directive, builder class] for every argument-builder
  # directive on the field's arguments, in SDL order, then on the fields of the
  # input objects the client sent for them (each of a list), at any depth,
  # as PHP Lighthouse's applyArgBuilderDirectives goes through them. `values`
  # holds the node's value: the arguments, or the input object it is a field of.
  def arg_builders(args_h)
    builders_in(@field_def.arguments, args_h)
  end

  # The argument definitions and their directives are Support::ArgumentWalk's, as
  # the schema's build sees them; the values guide the walk into input objects.
  def builders_in(arguments, values)
    registry = Lighthouse::DirectiveRegistry.default
    walk = Lighthouse::Support::ArgumentWalk
    arguments.each_value.flat_map do |argument|
      node = argument.ast_node
      next [] unless node

      own = walk.directives(argument).filter_map do |dnode|
        builder_class = dnode.name == 'builder' ? :builder : registry.arg_builder_class(dnode.name)
        [values, node, dnode, builder_class] if builder_class
      end
      own + nested_builders(argument, dig_arg(values, [node.name]))
    end
  end

  def nested_builders(argument, value)
    fields = Lighthouse::Support::ArgumentWalk.input_fields(argument)
    return [] if value.nil? || fields.empty?

    [value].flatten.compact.flat_map { |input| builders_in(fields, input) }
  end

  # The client's value at `path` (an argument, then input fields), or nil.
  def dig_arg(args_h, path)
    path.reduce(args_h) do |value, name|
      hash = value.respond_to?(:to_h) && !value.is_a?(Array) ? value.to_h : value
      break nil unless hash.is_a?(Hash)

      Lighthouse::Support::Naming.fetch_arg(hash, name)
    end
  end
end
