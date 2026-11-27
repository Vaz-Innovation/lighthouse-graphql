# frozen_string_literal: true

# What TypeAuthorization reads of a schema when it is built: its object types
# whose classes define scope_items, by name and by the name of their model, and
# the names of its interfaces and unions.
Lighthouse::GraphQL::TypeAuthorization::Index = Struct.new(:scoped, :scoped_by_model, :abstract) do
  # `scoped_types`: the schema's object types whose classes define scope_items.
  def self.build(schema, scoped_types)
    by_model = Hash.new { |hash, model| hash[model] = [] }
    scoped_types.each do |type|
      model = Lighthouse::GraphQL::Directives::ModelDirective.model_for(type)
      by_model[model.name] << type.graphql_name if model
    end
    abstract = schema.types.each_value.select { |type| type.kind.abstract? }.to_set(&:graphql_name)
    new(scoped_types.to_set(&:graphql_name).freeze, by_model.transform_values(&:freeze).freeze, abstract.freeze).freeze
  end

  def scoped?(name) = scoped.include?(name)
  def scoped_of(model) = scoped_by_model.fetch(model, [])
  def abstract?(name) = abstract.include?(name)
end
Lighthouse::GraphQL::TypeAuthorization::Index::EMPTY =
  Lighthouse::GraphQL::TypeAuthorization::Index.new(Set.new.freeze, {}.freeze, Set.new.freeze).freeze
