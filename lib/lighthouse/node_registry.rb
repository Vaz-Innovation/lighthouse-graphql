# frozen_string_literal: true

# Resolves Relay's `Query.node(id:)`, which @node adds, as PHP Lighthouse's
# NodeRegistry: the id is decoded into a type and an id, and the type must be
# one with @node. Its object comes from, in order:
#
# - `@node(resolver: "Class@method")`: the class (method `call` without `@`),
#   looked up as @field looks a class up on a type, called with the id and the
#   context;
# - `@node(model: "Name")`, or else the type's @model, or else the model named
#   after the type:
#   the record with that primary key, batched across every `node` in the query.
#
# It also tells the Node interface which type each object is (resolve_type):
# `node` hands back the object with the type its id named, so a `resolver:` may
# return any object, a Hash included, and one record may be two node types.
class Lighthouse::GraphQL::NodeRegistry
  # What `node` returns: the object, and the type its global id named.
  Found = Struct.new(:type, :object)

  def self.resolve(_root, args, context, _info = nil)
    type_name, id = args[:id]
    type = context.schema.get_type(type_name.to_s)
    raise ::GraphQL::ExecutionError, "[#{type_name}] is not a type that can be resolved by node." unless node_type?(type)

    object = find(type, id, context)
    object.nil? ? nil : Found.new(type, object)
  end

  # [type, object] for what `node` found; nil leaves any other Node value to the default.
  def self.resolve_type(object, _context)
    [object.type, object.object] if object.is_a?(Found)
  end

  def self.node_type?(type)
    type&.kind&.object? && !directive(type).nil?
  end

  def self.directive(type)
    (type.ast_node&.directives || []).find { |d| d.name == 'node' }
  end

  def self.find(type, id, context)
    node = directive(type)
    resolver = Lighthouse::Support::DirectiveArgs.literal(node, 'resolver')
    return call_resolver(resolver, id, context) if resolver

    model = model_for(type, Lighthouse::Support::DirectiveArgs.literal(node, 'model'))
    raise Lighthouse::DefinitionError, "@node on #{type.graphql_name} finds no model: give it model: or resolver:." unless model

    context.dataloader.with(::GraphQL::Dataloader::ActiveRecordSource, model).load(model.type_for_attribute(model.primary_key).cast(id))
  end

  def self.call_resolver(reference, id, context)
    class_name, method = Lighthouse::GraphQL::DirectiveResolvers::FieldDirectiveResolver.reference(reference)
    klass = Lighthouse::GraphQL::DirectiveResolvers::FieldDirectiveResolver.lookup(class_name, nil)
    raise Lighthouse::DefinitionError, "@node(resolver: #{reference.inspect}) names no class." unless klass

    receiver = Lighthouse::GraphQL::ResolverDispatch.callable_receiver(klass, method || :call)
    receiver.public_send(method || :call, id, context)
  end

  def self.model_for(type, name)
    return Lighthouse::Support::ModelResolver.constantize(name) if name

    Lighthouse::GraphQL::Directives::ModelDirective.model_for(type)
  end
end
