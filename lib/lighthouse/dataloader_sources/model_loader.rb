# frozen_string_literal: true

# The records of a model by id, for @find's batched lookups: one query for
# every id the Dataloader collected, narrowed by the scope_items of the field's
# type when it has one (TypeAuthorization), in the same query.
class Lighthouse::GraphQL::DataloaderSources::ModelLoader < GraphQL::Dataloader::Source
  # `scoping`: the type class whose scope_items applies, and the query's context.
  def initialize(model_class, scoping = nil, context = nil)
    super()
    @model_class = model_class
    @scoping = scoping
    @context = context
  end

  # Keys are ids. GraphQL `ID` arguments arrive as strings while records
  # carry their column type (usually Integer), so match on the string form.
  def fetch(keys)
    relation = @model_class.where(id: keys)
    relation = Lighthouse::GraphQL::TypeAuthorization.narrowed(@scoping, relation, @context) if @scoping
    records = relation.index_by { |record| record.id.to_s }
    keys.map { |k| records[k.to_s] }
  end
end
