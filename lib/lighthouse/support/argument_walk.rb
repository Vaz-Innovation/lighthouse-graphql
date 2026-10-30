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
end
