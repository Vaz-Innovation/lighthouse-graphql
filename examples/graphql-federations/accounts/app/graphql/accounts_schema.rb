# Lighthouse builds the subgraph from graphql/schema.graphql, on the classes
# graphql-ruby's install writes (base_types), as in ../../../graphql.
class AccountsSchema < Lighthouse::GraphQL::RbLightHouse.get_schema(
  options: {
    base_types: {
      query_type: Types::QueryType,
      mutation_type: Types::MutationType,
      resolver: Resolvers::BaseResolver,
      mutation: Mutations::BaseMutation,
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

  # The router asks for entities in `_entities`, nested deeper than the query a client sent.
  max_depth(20)
  max_complexity(2000)
end
