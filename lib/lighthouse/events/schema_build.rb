# frozen_string_literal: true

# The events of the schema build, as SchemaGenerator.build_document meets them.
module Lighthouse::Events::SchemaBuild
  module_function

  # Dispatch RegisterDirectiveNamespaces and register every directive class
  # under the namespaces the listeners return (a Module, its name, or an
  # Array of them), in the default registry.
  def register_directive_namespaces(registry = Lighthouse::DirectiveRegistry.default)
    namespaces = Lighthouse::Events.dispatch(Lighthouse::Events::RegisterDirectiveNamespaces.new).flatten
    namespaces = namespaces.select { |namespace| namespace.is_a?(String) || namespace.is_a?(Module) }
    namespaces.each { |namespace| register_namespace(resolve_namespace(namespace), registry) }
  end

  # The SDL with what the listeners of BuildSchemaString return appended.
  def schema_string(sdl)
    return sdl unless sdl.is_a?(String)

    added = Lighthouse::Events.dispatch(Lighthouse::Events::BuildSchemaString.new(sdl)).flatten.grep(String)
    added.empty? ? sdl : [sdl, *added].join("\n")
  end

  # The document the listeners of ManipulateAST leave on the event.
  def manipulate_ast(document)
    event = Lighthouse::Events::ManipulateAST.new(document)
    Lighthouse::Events.dispatch(event)
    event.document_ast
  end

  def resolve_namespace(namespace)
    return namespace if namespace.is_a?(Module)

    Lighthouse::Support::ModelResolver.constantize(namespace, namespaces: []) ||
      raise(Lighthouse::DefinitionError, "RegisterDirectiveNamespaces: no namespace #{namespace}")
  end

  def register_namespace(namespace, registry)
    namespace.constants(false).each do |name|
      directive = namespace.const_get(name)
      registry.register(directive) if directive.respond_to?(:directive_name)
    end
  end
end
