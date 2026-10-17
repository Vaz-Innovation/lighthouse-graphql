# frozen_string_literal: true

# Object-level Apollo Federation directives (@key, @extends, @shareable,
# @inaccessible, @interfaceObject) applied to the types built from SDL, so the
# Apollo Federation helper can detect entities and add _entities. Only types
# that know federation (they answer `key`) are touched.
module Lighthouse::GraphQL::FederationDirectives
  # Directive => the type's federation method it calls. Each is called only
  # when the type has it, so a partial federation setup still builds.
  FLAGS = {
    'extends' => :extend_type,
    'shareable' => :shareable,
    'inaccessible' => :inaccessible,
    'interfaceObject' => :interface_object
  }.freeze

  module_function

  def apply(type)
    return unless type.ast_node && type.respond_to?(:key)

    type.ast_node.directives.each do |dnode|
      if dnode.name == 'key'
        apply_key(type, dnode)
      elsif (flag = FLAGS[dnode.name]) && type.respond_to?(flag)
        type.public_send(flag)
      end
    end
  end

  def apply_key(type, dnode)
    arg = dnode.arguments.find { |a| a.name == 'fields' }
    type.key(fields: arg.value) if arg.respond_to?(:value)

    resolve_references(type)
  end

  # Setup federation resolve_reference: prefer a custom resolver
  # registered with ReferenceResolver, but fall back to the base
  # type's own resolve_reference (e.g. BaseObject's default model
  # lookup) so direct-model entities resolve without a custom
  # handler. Capture the inherited implementation before shadowing.
  def resolve_references(type)
    default_resolve_reference = type.respond_to?(:resolve_reference) ? type.method(:resolve_reference) : nil

    type.define_singleton_method(:resolve_reference) do |reference, context|
      resolved = ::Lighthouse::ReferenceResolver.resolve(type.graphql_name, reference, context)
      next resolved unless resolved.nil?

      default_resolve_reference&.call(reference, context)
    end
  end
end
