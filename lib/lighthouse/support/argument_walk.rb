# frozen_string_literal: true

# The one walk through a field's arguments and the fields of the input types they
# take, so what is found when the schema is built (Search::FieldCheck, the
# @canModel on arguments) and when a query runs (BaseDirectiveResolver's argument
# builders) is the same: graphql-ruby's argument definitions, in SDL order, and the
# directives the SDL puts on each.
module Lighthouse::Support::ArgumentWalk
  module_function

  # The directives the SDL puts on an argument or input field.
  def directives(argument) = argument.ast_node&.directives || []

  # The fields of the input type an argument takes, by name; none for another type.
  def input_fields(argument)
    type = argument.type.unwrap
    type.kind.input_object? ? type.arguments : {}
  end

  # Does the argument take a list (of input objects, say)?
  def list?(argument)
    (argument.type.non_null? ? argument.type.of_type : argument.type).list?
  end

  # Support::ArgumentWalk.definitions of a field's arguments, walked once per
  # field when the schema is built (for its searches and its @canModel), and kept
  # on the field: a schema built again on reload starts afresh.
  def field_definitions(field_def)
    return field_def.instance_variable_get(:@lighthouse_argument_walk) if field_def.instance_variable_defined?(:@lighthouse_argument_walk)

    field_def.instance_variable_set(:@lighthouse_argument_walk, definitions(field_def.arguments).freeze)
  end

  # [dot path ("filter.trashed", "inputs.*.status"), argument] for every argument
  # and input field, at any depth, each before the fields of its input type; `*`
  # steps into each of a list. An input type is not walked twice on one path.
  def definitions(arguments, prefix = nil, seen = Set.new)
    arguments.each_value.flat_map do |argument|
      path = [prefix, argument.graphql_name].compact.join('.')
      type_name = argument.type.unwrap.graphql_name
      nested = seen.include?(type_name) ? {} : input_fields(argument)
      [[path, argument], *definitions(nested, list?(argument) ? "#{path}.*" : path, seen | [type_name])]
    end
  end

  # [path, argument] for every argument and input field that holds a value when
  # the client sends none for it, as graphql-ruby fills defaults in: an omitted
  # argument's default value; within an input object, the value its default
  # literal gives a field, else the field's own default. An input object holds
  # values when a default gives it, or when the client must send it (non-null,
  # no default): its fields' defaults apply then. A field's default under a
  # parent the client may leave out applies only when the client sends the parent.
  # `literal`: what a default gives this level (by GraphQL name); nil at the top.
  def implicit(arguments, literal = nil, prefix = nil, seen = Set.new)
    arguments.each_value.flat_map do |argument|
      name = argument.graphql_name
      path = [prefix, name].compact.join('.')
      value = literal&.key?(name) ? literal[name] : (argument.default_value if argument.default_value?)
      [*([[path, argument]] unless value.nil?), *implicit_fields(argument, value, path, seen)]
    end
  end

  def implicit_fields(argument, value, path, seen)
    type_name = argument.type.unwrap.graphql_name
    fields = input_fields(argument)
    return [] if fields.empty? || seen.include?(type_name)

    prefix = list?(argument) ? "#{path}.*" : path
    implicit_objects(argument, value).flat_map { |object| implicit(fields, object, prefix, seen | [type_name]) }
  end
  private_class_method :implicit_fields

  # The input objects an argument holds without the client: those its value
  # gives, else an empty one the client must send (non-null, no default).
  def implicit_objects(argument, value)
    return argument.type.non_null? ? [{}] : [] if value.nil?

    (value.is_a?(Array) ? value : [value]).grep(Hash)
  end
  private_class_method :implicit_objects
end
