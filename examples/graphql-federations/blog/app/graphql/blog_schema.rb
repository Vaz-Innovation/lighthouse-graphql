# Lighthouse builds the subgraph from graphql/schema.graphql, on the classes
# graphql-ruby's install writes (base_types), as in ../../../graphql.
class BlogSchema < Lighthouse::GraphQL::RbLightHouse.get_schema(
  options: {
    base_types: {
      query_type: Types::QueryType,
      mutation_type: Types::MutationType,
      node: Types::NodeType,
      resolver: Resolvers::BaseResolver,
      mutation: Mutations::BaseMutation,
      subscription: Subscriptions::BaseSubscription,
      object: Types::BaseObject,
      interface: Types::BaseInterface,
      union: Types::BaseUnion,
      scalar: Types::BaseScalar,
      enum: Types::BaseEnum,
      input_object: Types::BaseInputObject
    }
  }
)
  use GraphQL::Dataloader

  # The Subscription type's fields reach clients through Apollo Router, which asks
  # for them with an HTTP callback (its `subscription.mode.callback`): every update
  # @broadcast triggers is sent to the router, which resolves the other subgraphs'
  # fields of it. Guide: ../../../docs/federation.md#subscriptions
  use Lighthouse::GraphQL::Federation::CallbackSubscriptions

  # The router asks for entities in `_entities`, nested deeper than the query a client sent.
  max_depth(20)
  max_complexity(2000)

  # Relay-style Object Identification (Query.node, Tag's @globalId), with Rails' GlobalID.
  def self.id_from_object(object, _type_definition, _query_ctx)
    object.to_gid_param
  end

  def self.object_from_id(global_id, _query_ctx)
    GlobalID.find(global_id)
  end
end
