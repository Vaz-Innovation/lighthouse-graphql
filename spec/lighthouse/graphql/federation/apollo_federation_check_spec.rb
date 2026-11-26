# frozen_string_literal: true

RSpec.describe Lighthouse::GraphQL::Federation::ApolloFederationCheck do
  let(:sdl) do
    <<~GRAPHQL
      extend schema @link(url: "https://specs.apollo.dev/federation/v2.9", import: ["@key"])
      type Query { user: User }
      type User @key(fields: "id") { id: ID! role: Role }
      enum Role { ADMIN }
    GRAPHQL
  end

  # The apollo-federation gem's mixins, by name: stand-ins, the gem is not in the bundle.
  let(:apollo) do
    Module.new.tap do |apollo|
      %w[Schema Object Interface Union Enum EnumValue Scalar InputObject Field Argument].each { |name| apollo.const_set(name, Module.new) }
    end
  end

  before { stub_const('ApolloFederation', apollo) }

  def build(**base_types) = build_schema(sdl, base_types: base_types)

  it 'refuses a base object with the gem’s mixin, naming it and what replaces it' do
    object = Class.new(GraphQL::Schema::Object) { include ApolloFederation::Object }
    stub_const('Types::BaseObject', object)

    expect { build(object: object) }.to raise_error(Lighthouse::DefinitionError,
                                                    /Types::BaseObject includes ApolloFederation::Object \(`key fields:`.*→ @key/)
  end

  it 'finds the mixins of the field, argument and enum value classes the base types use' do
    argument = Class.new(GraphQL::Schema::Argument) { include ApolloFederation::Argument }
    field = Class.new(GraphQL::Schema::Field) { include ApolloFederation::Field }
    field.argument_class(argument)
    enum_value = Class.new(GraphQL::Schema::EnumValue) { include ApolloFederation::EnumValue }
    stub_const('Types::BaseField', field)
    stub_const('Types::BaseArgument', argument)
    stub_const('Types::BaseEnumValue', enum_value)
    object = Class.new(GraphQL::Schema::Object) { field_class field }
    enum = Class.new(GraphQL::Schema::Enum) { enum_value_class enum_value }

    expect { build(object: object, enum: enum) }.to raise_error(Lighthouse::DefinitionError) { |error|
      expect(error.message).to include('Types::BaseField includes ApolloFederation::Field', 'Types::BaseArgument includes ApolloFederation::Argument',
                                       'Types::BaseEnumValue includes ApolloFederation::EnumValue')
    }
  end

  it 'refuses every kind of base type with its mixin' do
    interface = Module.new do
      include GraphQL::Schema::Interface
      include ApolloFederation::Interface
    end
    union = Class.new(GraphQL::Schema::Union) { include ApolloFederation::Union }
    scalar = Class.new(GraphQL::Schema::Scalar) { include ApolloFederation::Scalar }
    input = Class.new(GraphQL::Schema::InputObject) { include ApolloFederation::InputObject }
    enum = Class.new(GraphQL::Schema::Enum) { include ApolloFederation::Enum }

    expect { build(interface: interface, union: union, scalar: scalar, input_object: input, enum: enum) }
      .to raise_error(Lighthouse::DefinitionError, /Interface.*Union.*Scalar.*InputObject.*Enum/m)
  end

  it "refuses ApolloFederation::Schema in the app's schema class, as it is included" do
    base = build

    expect { Class.new(base) { include ApolloFederation::Schema } }
      .to raise_error(Lighthouse::DefinitionError, /includes ApolloFederation::Schema, whose subgraph SDL and _entities would replace Lighthouse's/)
    expect { Class.new(base) { include Comparable } }.not_to raise_error
  end

  it 'builds base types without the mixins, and anything at all without the gem' do
    expect { build(object: Class.new(GraphQL::Schema::Object)) }.not_to raise_error

    hide_const('ApolloFederation')
    expect { build }.not_to raise_error
  end
end
