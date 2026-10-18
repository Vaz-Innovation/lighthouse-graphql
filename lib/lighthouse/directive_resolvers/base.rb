# frozen_string_literal: true

class Lighthouse::GraphQL::DirectiveResolvers::BaseDirectiveResolver
  def initialize(field_def, type_def, directive_node, opts = {})
    @field_def = field_def
    @type_def = type_def
    @directive_node = directive_node
    @opts = opts
  end

  def define_resolver(target_type_class)
    raise NotImplementedError
  end

  # `ctx`: the query's context, for @builder on an argument.
  def apply_where_filters(relation, args, ctx = nil)
    return relation unless relation.respond_to?(:where)

    args_h = args.respond_to?(:to_h) ? args.to_h : (args || {})

    relation = apply_where_conditions(relation, args_h)
    @field_def.ast_node.arguments.each do |arg_node|
      relation = apply_where_has_conditions(relation, arg_node, args_h)
    end

    apply_arg_builders(relation, args_h, ctx)
  rescue ::GraphQL::ExecutionError
    raise
  rescue StandardError => e
    Lighthouse::Config.handle_error(e)
    relation
  end

  # Compose argument-builder directives (@eq, @neq, @in, @notIn, @like,
  # @where, @orderBy) onto the relation, in SDL argument order, for each
  # field argument that carries one and that the client supplied a value
  # for — and for the input fields of an argument carrying @nest.
  def apply_arg_builders(relation, args_h, ctx = nil)
    return relation unless relation.respond_to?(:where)
    return relation unless @field_def.ast_node

    arg_builders.each do |path, arg_node, dnode, builder_class|
      relation = apply_arg_builder(relation, args_h, ctx, [path, arg_node, dnode, builder_class])
    end

    relation
  rescue ::GraphQL::ExecutionError
    raise
  rescue StandardError => e
    Lighthouse::Config.handle_error(e)
    relation
  end

  def extract_relation_name_from_directive(arg_node)
    directive = arg_node.directives.find { |dir| dir.name == 'whereHasConditions' }
    return nil unless directive

    relation_arg = directive.arguments.find { |arg| arg.name == 'relation' }
    return nil unless relation_arg

    relation_arg.value.respond_to?(:value) ? relation_arg.value.value : relation_arg.value
  rescue StandardError
    nil
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
    name = directive_arg('model') || sibling_model_name || return_type_model_name
    constantize_model(name) || raise(Lighthouse::DefinitionError,
                                     "@#{@directive_node&.name} on #{@type_def.graphql_name}.#{@field_def.name}: no model #{name}")
  end

  private

  def sibling_model_name
    (@field_def.ast_node&.directives || []).filter_map do |d|
      Lighthouse::Support::DirectiveArgs.literal(d, 'model')
    end.first
  end

  def return_type_model_name
    @field_def.type.unwrap.graphql_name.sub(/(SimplePaginator|Paginator|Connection)\z/, '')
  end

  # The `where:` argument (@whereConditions), when the client supplied one.
  def apply_where_conditions(relation, args_h)
    where_condition = args_h[:where] || args_h['where']
    return relation unless where_condition

    Lighthouse::GraphQL::DirectiveResolvers::WhereConditionsApplier.apply(relation, where_condition)
  end

  # A `whereHasConditions` argument the client supplied filters the
  # relation by the related records matching its condition.
  def apply_where_has_conditions(relation, arg_node, args_h)
    return relation unless arg_node.directives.any? { |dir| dir.name == 'whereHasConditions' }

    arg_value = Lighthouse::Support::Naming.fetch_arg(args_h, arg_node.name)
    return relation unless arg_value

    relation_name = extract_relation_name_from_directive(arg_node) || Lighthouse::Support::Naming.derive_relation_name(arg_node.name)
    Lighthouse::GraphQL::DirectiveResolvers::WhereConditionsApplier.apply_has_argument(relation, arg_node.name, arg_value, relation_name)
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

  # [path, node, directive, builder class] for every argument-builder
  # directive, in SDL order. An argument carrying @nest adds its input type's
  # fields', at any depth, with their path into the value.
  def arg_builders
    (@field_def.ast_node.arguments || []).flat_map do |arg_node|
      builders_of(arg_node, [arg_node.name], @field_def.arguments[arg_node.name])
    end
  end

  def builders_of(node, path, argument)
    registry = Lighthouse::DirectiveRegistry.default
    own = (node.directives || []).filter_map do |dnode|
      builder_class = dnode.name == 'builder' ? :builder : registry.arg_builder_class(dnode.name)
      [path, node, dnode, builder_class] if builder_class
    end
    own + (argument && nest?(node) ? nested_builders(argument, path) : [])
  end

  def nest?(node)
    (node.directives || []).any? { |d| d.name == 'nest' }
  end

  def nested_builders(argument, path)
    type = argument.type.unwrap
    return [] unless type.kind.input_object?

    type.arguments.each_value.flat_map do |field|
      field.ast_node ? builders_of(field.ast_node, path + [field.ast_node.name], field) : []
    end
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
