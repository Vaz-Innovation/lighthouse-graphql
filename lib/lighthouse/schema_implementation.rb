# frozen_string_literal: true

# Minimal SchemaImplementation used when the app doesn't provide one.
# It delegates runtime resolution to either:
# - singleton resolver methods attached to schema types (e.g. `Inbox.resolve_field_conversations`),
# - the field's resolve proc (if present),
# - or the object's method matching the field name.
class SchemaImplementation
  attr_accessor :schema

  def initialize
    @schema = nil
  end

  # Called by graphql-ruby as the default resolver: (type, field, obj, args, ctx)
  def call(type, field, obj, args, ctx)
    field_name = extract_field_name(field)

    # Prefer singleton resolver methods attached during post_process.
    resolver = generated_resolver(type, field_name)
    return Lighthouse::GraphQL::GeneratedResolvers.invoke(resolver, obj, args, ctx) if resolver

    # Use field-level resolve proc if available
    return field.resolve_proc.call(obj, args, ctx) if field.respond_to?(:resolve_proc) && field.resolve_proc
    return read_hash(obj, field_name) if obj.is_a?(Hash)

    read_attribute(obj, field_name)
  end

  # The object type of a union's or interface's value (see TypeResolution).
  def resolve_type(abstract_type, obj, ctx)
    schema = ctx.respond_to?(:schema) && ctx.schema ? ctx.schema : @schema
    Lighthouse::GraphQL::TypeResolution.resolve(schema, abstract_type, obj, ctx)
  end

  def coerce_input(_type, value, _ctx)
    value
  end

  def coerce_result(_type, value, _ctx)
    value
  end

  private

  # Our generated `resolve_field_<name>` on the first owner that has one: the
  # type itself, its type class, or the schema's type of the same name.
  def generated_resolver(type, field_name)
    method_name = Lighthouse::GraphQL::GeneratedResolvers.method_name(field_name)
    owner_candidates(type).each do |candidate|
      next unless candidate.respond_to?(method_name)

      resolver = candidate.method(method_name)
      return resolver if Lighthouse::GraphQL::GeneratedResolvers.generated?(resolver)
    end
    nil
  end

  def owner_candidates(type)
    candidates = [type]
    candidates << type.metadata[:type_class] if type.respond_to?(:metadata) && type.metadata.is_a?(Hash) && type.metadata[:type_class]
    candidates << lookup_owner_type(type)
    candidates.compact
  end

  # A Hash result is read by the field name as given, then in snake_case,
  # each as a String or Symbol key.
  def read_hash(hash, field_name)
    snake = naming_attribute(field_name)
    key = [field_name.to_s, field_name.to_sym, snake, snake.to_sym].find { |candidate| hash.key?(candidate) }
    key.nil? ? nil : hash[key]
  end

  # Fallback to reading the attribute off the Ruby object. Map the GraphQL
  # field name (camelCase) to the Rails attribute (snake_case) when the object
  # does not respond to the literal name, so e.g. `customAttributes` resolves
  # to `custom_attributes` without a per-field resolver.
  def read_attribute(obj, field_name)
    return obj.public_send(field_name) if obj.respond_to?(field_name)

    snake = naming_attribute(field_name)
    return obj.public_send(snake) if snake != field_name.to_s && obj.respond_to?(snake)

    nil
  end

  def naming_attribute(field_name)
    if defined?(Lighthouse::Support::Naming)
      Lighthouse::Support::Naming.attribute(field_name)
    else
      field_name.to_s.underscore
    end
  end

  def extract_field_name(field)
    if field.respond_to?(:graphql_name)
      field.graphql_name.to_s
    elsif field.respond_to?(:name)
      field.name.to_s
    else
      field.to_s
    end
  end

  def lookup_owner_type(type)
    return nil unless @schema

    type_name = if type.respond_to?(:graphql_name)
                  type.graphql_name
                elsif type.respond_to?(:name)
                  type.name.to_s
                else
                  type.to_s
                end

    @schema.types[type_name]
  end
end
