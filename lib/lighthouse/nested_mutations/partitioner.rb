# frozen_string_literal: true

# Splits one record's input into attributes and the operations on its
# associations (a Lighthouse::GraphQL::NestedMutations::Partition).
class Lighthouse::GraphQL::NestedMutations::Partitioner
  def initialize(model, input)
    @model = model
    @input = input
  end

  def call
    @part = Lighthouse::GraphQL::NestedMutations::Partition.new(argument_paths(@input.argument_defs, @input.path))
    walk(@input)
    @part
  end

  private

  def walk(input)
    by_keyword = Lighthouse::Support::Arguments.keyword_index(input.argument_defs)
    input.args.each_pair do |key, value|
      argument = by_keyword[key.to_sym]
      path = input.path + [argument ? argument.graphql_name : key.to_s.camelize(:lower)]
      attribute = (argument && renamed(argument)) || key.to_s
      assign(attribute, value, path) unless argument && nest(argument, attribute, value, path)
    end
  end

  # Takes the value of a @spread argument, of a nested operation argument
  # (@create(relation:) ...) or of an association's operations; false when
  # it is a plain attribute. A null for any of those is no operation at all.
  def nest(argument, attribute, value, path)
    if Lighthouse::Support::Arguments.spread?(argument)
      walk(spread_input(argument, value, path)) unless value.nil?
    elsif (directive = nested_directive(argument))
      add_argument_operation(directive, attribute, Lighthouse::GraphQL::NestedMutations::Operation.new(value, argument, path))
    elsif (reflection = relation_argument(attribute, argument))
      @part.add(reflection, operations(reflection, argument, value, path)) unless value.nil?
    else
      return false
    end
    true
  end

  # A @spread input object is walked as if its fields were the parent's.
  def spread_input(argument, value, path)
    Lighthouse::GraphQL::NestedMutations::Input.new(Lighthouse::Support::Arguments.shallow(value), argument.type.unwrap.arguments, path)
  end

  def assign(attribute, value, path)
    @part.attributes[attribute] = Lighthouse::Support::Arguments.plain(value)
    @part.paths[attribute] ||= path.join('.')
  end

  # An argument with @create/@update/@upsert/@delete is one operation on the
  # association its `relation:` names, else the one the argument is named after.
  def add_argument_operation(directive, attribute, operation)
    return if operation.value.nil?

    reflection = reflection!(Lighthouse::Support::DirectiveArgs.literal(directive, 'relation') || attribute)
    operation.identifying = identifying_columns(directive)
    @part.add(reflection, Lighthouse::GraphQL::NestedMutations::ARGUMENT_DIRECTIVES[directive.name] => operation)
  end

  # @upsert(identifyingColumns:) — nil when the directive does not set them.
  def identifying_columns(directive)
    return nil unless directive.arguments.any? { |a| a.name == 'identifyingColumns' }

    Array(Lighthouse::Support::DirectiveArgs.literal(directive, 'identifyingColumns'))
  end

  # An association-named argument whose type is an input object of operations.
  def relation_argument(attribute, argument)
    return nil unless argument.type.unwrap.kind.input_object?
    return nil unless @model.respond_to?(:reflect_on_association)

    @model.reflect_on_association(attribute.to_sym)
  end

  def operations(reflection, argument, value, path)
    kind = Lighthouse::GraphQL::NestedMutations.kind(reflection)
    allowed = Lighthouse::GraphQL::NestedMutations::OPERATIONS.fetch(kind)
    by_keyword = Lighthouse::Support::Arguments.keyword_index(argument.type.unwrap.arguments)
    Lighthouse::Support::Arguments.shallow(value).each_with_object({}) do |(key, operation_value), out|
      next if operation_value.nil?

      operation_argument = by_keyword[key.to_sym]
      name = operation_argument&.graphql_name || key.to_s.camelize(:lower)
      unless allowed.include?(name)
        raise Lighthouse::DefinitionError,
              "#{name} is not a nested operation on #{@model}##{reflection.name} (#{kind}): use #{allowed.join(', ')}."
      end

      out[name] = Lighthouse::GraphQL::NestedMutations::Operation.new(operation_value, operation_argument, path + [name])
    end
  end

  def nested_directive(argument)
    (argument.ast_node&.directives || []).find { |d| Lighthouse::GraphQL::NestedMutations::ARGUMENT_DIRECTIVES.key?(d.name) }
  end

  def reflection!(name)
    @model.reflect_on_association(name.to_s.underscore.to_sym) ||
      raise(Lighthouse::DefinitionError, "#{@model} has no association #{name} for a nested mutation.")
  end

  def renamed(argument)
    directive = (argument.ast_node&.directives || []).find { |d| d.name == 'rename' }
    directive && Lighthouse::Support::DirectiveArgs.literal(directive, 'attribute')
  end

  # { attribute => "argument.path" } for every argument the type defines —
  # also those the client left out, where e.g. a presence error belongs.
  def argument_paths(argument_defs, prefix)
    paths = Hash.new { |_, attribute| (prefix + [attribute.to_s.camelize(:lower)]).join('.') }
    (argument_defs || {}).each_value do |argument|
      if Lighthouse::Support::Arguments.spread?(argument)
        paths.merge!(argument_paths(argument.type.unwrap.arguments, prefix + [argument.graphql_name]))
      else
        paths[renamed(argument) || argument.keyword.to_s] = (prefix + [argument.graphql_name]).join('.')
      end
    end
    paths
  end
end
