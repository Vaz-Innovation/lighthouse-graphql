# frozen_string_literal: true

# Helper for "middleware" directives (@guard, @can) that need to wrap a
# field's existing resolver.
module Lighthouse::GraphQL::DirectiveResolvers::Resolution
  module_function

  # Capture the field's current resolver (generated singleton method,
  # resolve_proc, or the default attribute reader) as a callable
  # (obj, args, ctx) -> value, so it can be wrapped. The returned callable
  # is unaffected by subsequently redefining the singleton method.
  def capture(target_type_class, method_name, field_def, field_name)
    original_singleton = lighthouse_singleton(target_type_class, method_name)
    original_proc = field_def.resolve_proc if field_def.respond_to?(:resolve_proc) && field_def.resolve_proc

    lambda do |obj, arguments, ctx|
      if original_singleton
        original_singleton.call(obj, arguments, ctx)
      elsif original_proc
        original_proc.call(obj, arguments, ctx)
      else
        Lighthouse::GraphQL::DirectiveResolvers::Resolution.read(obj, field_name)
      end
    end
  end

  # The default reader: a Hash's key, else the object's method of the field's
  # name or its snake_case.
  def read(obj, field_name)
    return read_hash(obj, field_name) if obj.is_a?(Hash)
    return obj.public_send(field_name) if obj.respond_to?(field_name)

    snake = Lighthouse::Support::Naming.attribute(field_name)
    obj.respond_to?(snake) ? obj.public_send(snake) : nil
  end

  # A Hash's value for the field, as the default reader finds it: by the field's
  # name or its snake_case, as a String or a Symbol key.
  def read_hash(hash, field_name)
    snake = Lighthouse::Support::Naming.attribute(field_name)
    key = [field_name.to_s, field_name.to_sym, snake, snake.to_sym].find { |candidate| hash.key?(candidate) }
    key.nil? ? nil : hash[key]
  end

  # graphql-ruby's SDL builder defines `resolve_field_*` methods of its own
  # (with a different arity); only ours, defined under lib/lighthouse/, count.
  def lighthouse_singleton(target_type_class, method_name)
    return nil unless target_type_class.respond_to?(method_name)

    method = target_type_class.method(method_name)
    source_file, = method.source_location
    method if source_file&.include?('/lib/lighthouse/')
  end
end
