# frozen_string_literal: true

require 'apollo-federation'

# Minimal federation-aware base object for building federated test schemas.
# Mirrors what a host app provides via `base_types`: an object type whose
# default `resolve_reference` looks the entity up by id on the model that shares
# its GraphQL type name.
module FederationTestTypes
  class BaseObject < ::GraphQL::Schema::Object
    include ApolloFederation::Object

    def self.resolve_reference(reference, _context)
      model = begin
        Object.const_get(graphql_name)
      rescue NameError
        nil
      end
      return nil unless model.respond_to?(:find_by)

      model.find_by(id: reference[:id] || reference['id'])
    end
  end
end

# Helpers exposed to every example for building schemas from inline SDL.
module SchemaBuilders
  def build_schema(sdl, federation: false, base_types: {})
    Lighthouse::GraphQL::SchemaFactory.build_base_schema(
      sdl: sdl,
      base_types: base_types,
      federation: federation
    )
  end

  FEDERATION_DIRECTIVES = <<~GRAPHQL
    directive @key(fields: String!) repeatable on INTERFACE | OBJECT
    directive @external on FIELD_DEFINITION
    directive @extends on OBJECT | INTERFACE
    directive @shareable on FIELD_DEFINITION | OBJECT
    directive @inaccessible on FIELD_DEFINITION
  GRAPHQL

  def build_federated_schema(sdl)
    build_schema(
      "#{FEDERATION_DIRECTIVES}\n#{sdl}",
      federation: true,
      base_types: { object: FederationTestTypes::BaseObject }
    )
  end
end

RSpec.configure do |config|
  config.include SchemaBuilders
end
