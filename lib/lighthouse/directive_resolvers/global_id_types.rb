# frozen_string_literal: true

# The model a field's @globalId arguments decode ids of, so another type's
# id fails the field instead of finding the record with the same number
# (`user(id: <a Post's id>)`). PHP Lighthouse checks nothing.
#
# - `@globalId(type: "User")`: that type (a GraphQL type or model name), any decode mode.
# - With decode: ID and no type:, the field's model (its `model:`, else its
#   return type's), for an argument that filters that model by its key: one
#   with @whereKey, an @eq / @in on the primary key, or one named after it
#   (`id`). That is a field's argument, or a field of an input object one of
#   its arguments takes, unless that argument is an association of the model
#   (whose own ids it holds). Elsewhere (`authorId`, the inputs of nested
#   mutations) the id is of another model, which `type:` names.
#
# Models are looked up per call, so code reloading works.
class Lighthouse::GraphQL::DirectiveResolvers::GlobalIdTypes
  KEY_FILTERS = %w[eq in].freeze

  def initialize(resolver, field_def)
    @resolver = resolver
    @keys = key_arguments(field_def)
  end

  # The class the ids `argument` decodes must be of; nil: any.
  def model(directive, argument, mode, ctx)
    explicit = Lighthouse::Support::DirectiveArgs.literal(directive, 'type')
    return explicit_model(explicit, ctx) if explicit
    return unless mode.to_s == 'ID' && @keys.key?(argument)

    column, parent = @keys[argument]
    model = field_model
    model if model && keyed?(model, column, parent)
  end

  private

  def explicit_model(name, ctx)
    Lighthouse::GraphQL::GlobalId.type_model(name, ctx) ||
      raise(Lighthouse::DefinitionError, "@globalId(type: #{name.inspect}): no such type or model.")
  end

  def keyed?(model, column, parent)
    return false if parent && model.reflect_on_association(Lighthouse::Support::Naming.attribute(parent))

    column == :primary_key || column == model.primary_key.to_s
  end

  # The field's model, when it has one: a field returning a scalar has none.
  def field_model
    Lighthouse::Support::ModelResolver.model_class(@resolver.send(:model_class))
  rescue Lighthouse::DefinitionError
    nil
  end

  # { argument => [the column it filters, the argument whose input it is a field of] },
  # by identity, for the @globalId(decode: ID) arguments and their inputs' fields.
  def key_arguments(field_def)
    keys = {}.compare_by_identity
    field_def.arguments.each_value do |argument|
      keys[argument] = [column(argument), nil] if decodes_id?(argument)
      type = argument.type.unwrap
      next unless type.kind.input_object?

      type.arguments.each_value { |field| keys[field] = [column(field), argument.graphql_name] if decodes_id?(field) }
    end
    keys
  end

  def decodes_id?(argument)
    directives(argument).any? { |d| d.name == 'globalId' && Lighthouse::Support::DirectiveArgs.literal(d, 'decode') == 'ID' }
  end

  def column(argument)
    nodes = directives(argument)
    return :primary_key if nodes.any? { |d| d.name == 'whereKey' }

    filter = nodes.find { |d| KEY_FILTERS.include?(d.name) }
    (Lighthouse::Support::DirectiveArgs.literal(filter, 'key') || Lighthouse::Support::Naming.attribute(argument.graphql_name)).to_s
  end

  def directives(argument) = argument.ast_node&.directives || []
end
