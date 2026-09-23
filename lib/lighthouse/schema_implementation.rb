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

    # Prefer singleton resolver methods attached during post_process
    owner_candidates = [type]
    if type.respond_to?(:metadata) && type.metadata.is_a?(Hash) && type.metadata[:type_class]
      owner_candidates << type.metadata[:type_class]
    end
    owner_candidates << lookup_owner_type(type)

    resolver_method_name = "resolve_field_#{field_name}"
    owner = owner_candidates.compact.find do |cand|
      next false unless cand.respond_to?(resolver_method_name)
      m = cand.method(resolver_method_name)
      source_file, = m.source_location
      source_file && source_file.include?('/lib/lighthouse/')
    end

    if owner
      resolver = owner.method(resolver_method_name)
      param_count = resolver.parameters.length
      return resolver.call(obj, args) if param_count == 2
      resolver.call(obj, args, ctx)
    end

    # Use field-level resolve proc if available
    if field.respond_to?(:resolve_proc) && field.resolve_proc
      return field.resolve_proc.call(obj, args, ctx)
    end

    if obj.is_a?(Hash)
      return obj[field_name.to_s] if obj.key?(field_name.to_s)
      return obj[field_name.to_sym] if obj.key?(field_name.to_sym)

      snake = naming_attribute(field_name)
      return obj[snake] if obj.key?(snake)
      return obj[snake.to_sym] if obj.key?(snake.to_sym)

      return nil
    end

    # Fallback to reading the attribute off the Ruby object. Map the GraphQL
    # field name (camelCase) to the Rails attribute (snake_case) when the object
    # does not respond to the literal name, so e.g. `customAttributes` resolves
    # to `custom_attributes` without a per-field resolver.
    return obj.public_send(field_name) if obj.respond_to?(field_name)

    snake = naming_attribute(field_name)
    return obj.public_send(snake) if snake != field_name.to_s && obj.respond_to?(snake)

    nil
  end

  def resolve_type(abstract_type, obj, ctx)
    # Try to resolve to a Ruby type class under Types::<Name>Type
    type_name = abstract_type.respond_to?(:name) ? abstract_type.name : abstract_type.to_s
    begin
      Object.const_get("Types::#{type_name}Type")
    rescue StandardError
      nil
    end
  end

  def coerce_input(type, value, ctx)
    value
  end

  def coerce_result(type, value, ctx)
    value
  end

  private

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
