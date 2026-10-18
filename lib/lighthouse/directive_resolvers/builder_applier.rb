# frozen_string_literal: true

require_relative 'base'

# The field-level query directives, in SDL order, as PHP Lighthouse's field
# builder directives: @builder classes, @whereAuth, which keeps the records the
# signed-in user owns, and the registry's FieldBuilder directives (@orderBy on a
# field). They apply after the argument directives (apply_where_filters), so
# a builder's order breaks the ties of the client's orderBy. @builder on an
# argument is applied with the other argument directives (apply_argument).
#
# A builder is `class:` and `method:` (default `call`), or PHP Lighthouse's
# `method: "Class@method"`, looked up in Config.namespaces[:builders]. It gets
# the relation, a second value and the context, and returns the relation:
#
#   on a field                 (relation, args, context), or the directive's `value:` instead of args
#   on an argument             (relation, the argument's value, context), whenever the client sends
#                              the argument, null included
class Lighthouse::GraphQL::DirectiveResolvers::BuilderApplier
  DEFINITION = <<~GRAPHQL.chomp
    """
    Manipulate the query builder with a method.
    """
    directive @builder(
      "The builder class, in the builders namespace."
      class: String
      "The method to call: a name (default `call`), or a class and a method separated by `@`."
      method: String
      "On a field, the value the method gets after the relation, instead of the arguments."
      value: BuilderValue
    ) repeatable on ARGUMENT_DEFINITION | INPUT_FIELD_DEFINITION | FIELD_DEFINITION
  GRAPHQL

  TYPE_DEFINITIONS = {
    'BuilderValue' => <<~GRAPHQL.chomp
      "Any constant literal value: https://graphql.github.io/graphql-spec/draft/#sec-Input-Values"
      scalar BuilderValue
    GRAPHQL
  }.freeze

  WHERE_AUTH_DEFINITION = <<~GRAPHQL.chomp
    """
    Filter a type to only return instances owned by the current user.
    """
    directive @whereAuth(
      "The relation of the model that links it to the user: a belongs_to, a has_many, a :through."
      relation: String!
      "Accepted for PHP Lighthouse parity: the user is Config.authenticated_user's."
      guards: [String!]
    ) on FIELD_DEFINITION
  GRAPHQL

  DEFINITIONS = { 'builder' => DEFINITION, 'whereAuth' => WHERE_AUTH_DEFINITION }.freeze

  def self.apply(relation, field_def_ast_node, args, ctx, resolver_instance)
    return relation unless field_def_ast_node&.directives

    registry = Lighthouse::DirectiveRegistry.default
    field_def_ast_node.directives.reduce(relation) do |acc, directive_node|
      case directive_node.name
      when 'builder' then apply_directive(acc, directive_node, args, ctx, resolver_instance)
      when 'whereAuth' then where_auth(acc, directive_node, ctx)
      else field_builder(registry, acc, field_def_ast_node, directive_node)
      end
    end
  end

  # Does the field carry a query directive of its own?
  def self.any?(field_def_ast_node)
    registry = Lighthouse::DirectiveRegistry.default
    (field_def_ast_node&.directives || []).any? { |d| DEFINITIONS.key?(d.name) || registry.field_builder_class(d.name) }
  end

  def self.field_builder(registry, relation, field_def_ast_node, directive_node)
    builder_class = registry.field_builder_class(directive_node.name)
    builder_class ? builder_class.new(field_def_ast_node, directive_node).handle_field_builder(relation) : relation
  end
  private_class_method :field_builder

  # The records whose `relation:` links them to the signed-in user; none for a guest.
  def self.where_auth(relation, directive_node, ctx)
    user = Lighthouse::Support::Authorization.authenticated_user(ctx)
    return relation.none unless user

    model = relation.klass
    name = extract_directive_arg(directive_node, 'relation').to_sym
    reflection = model.reflect_on_association(name)
    raise Lighthouse::DefinitionError, "@whereAuth: #{model} has no relation #{name}." unless reflection
    return relation.where(name => user) if reflection.belongs_to?

    owned = model.unscoped.joins(name).where(reflection.klass.table_name => { reflection.klass.primary_key => user.id })
    relation.where(model.primary_key => owned.select(model.arel_table[model.primary_key]))
  end

  def self.apply_directive(relation, directive_node, args, ctx, _resolver_instance)
    value = directive_node.arguments&.any? { |a| a.name == 'value' } ? extract_directive_arg(directive_node, 'value') : args
    call_builder(relation, directive_node, value, ctx)
  end

  # @builder on an argument the client sent: the method gets its value.
  def self.apply_argument(relation, directive_node, value, ctx)
    call_builder(relation, directive_node, value, ctx)
  end

  def self.call_builder(relation, directive_node, value, ctx)
    builder_class, method_name = reference(directive_node)
    return relation unless builder_class

    receiver = builder_receiver(builder_class, method_name)
    return relation unless receiver

    receiver.public_send(method_name, relation, value, ctx) || relation
  rescue ::GraphQL::ExecutionError
    # Client-facing errors (e.g. authorization / scoping guards raised by a
    # builder) MUST propagate — never silently fall back to the unscoped
    # relation, or a builder that enforces tenancy could be bypassed.
    raise
  rescue StandardError => e
    Lighthouse::Config.handle_error(e)
    relation
  end

  # [builder class, method name] from `class:` and `method:`, or from
  # `method: "Class@method"`. Builders are not resolvers: they live in their
  # own namespace (Config.namespaces[:builders], app/graphql/builders).
  def self.reference(directive_node)
    class_name = extract_directive_arg(directive_node, 'class')
    method_name = extract_directive_arg(directive_node, 'method')
    class_name, method_name = method_name.to_s.split('@', 2) if class_name.nil? && method_name
    return [nil, nil] unless class_name

    builder_class = Lighthouse::Support::ModelResolver.constantize(class_name, namespaces: Lighthouse::Config.namespaces[:builders])
    [builder_class, method_name.presence || 'call']
  end

  def self.extract_directive_arg(directive_node, name)
    Lighthouse::Support::DirectiveArgs.literal(directive_node, name)
  end

  # What answers the builder method: the class itself, else an instance
  # of it; nil when neither does.
  def self.builder_receiver(builder_class, method_name)
    return builder_class if builder_class.respond_to?(method_name)
    return nil unless builder_class.is_a?(Class)

    instance = builder_class.new
    instance if instance.respond_to?(method_name)
  end
  private_class_method :builder_receiver
end
