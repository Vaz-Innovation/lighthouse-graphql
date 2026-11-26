# frozen_string_literal: true

module Types
  class QueryType < Types::BaseObject
    # Query.node and nodes are declared in graphql/schema.graphql; these methods resolve them.
    def node(id:)
      context.schema.object_from_id(id, context)
    end

    def nodes(ids:)
      ids.map { |id| context.schema.object_from_id(id, context) }
    end

    # Add root-level fields here.
    # They will be entry points for queries on your schema.
  end
end
