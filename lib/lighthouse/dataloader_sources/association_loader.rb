# frozen_string_literal: true

# Loads one association for many parents in a single query per batch, with
# ActiveRecord's preloader — the N+1 fix behind @hasMany, @belongsTo, ...
class Lighthouse::GraphQL::DataloaderSources::AssociationLoader < GraphQL::Dataloader::Source
  def initialize(model_class, association_name)
    super()
    @model_class = model_class
    @association_name = association_name.to_s
  end

  # keys: the parent records
  def fetch(parents)
    preload(parents.select { |parent| association?(parent) })
    parents.map { |parent| parent.respond_to?(@association_name) ? parent.public_send(@association_name) : nil }
  end

  private

  def association?(parent)
    parent.class.respond_to?(:reflect_on_association) && parent.class.reflect_on_association(@association_name)
  end

  def preload(records)
    return if records.empty?

    preloader = ::ActiveRecord::Associations::Preloader
    if preloader.method_defined?(:call)
      preloader.new(records: records, associations: @association_name.to_sym).call # Rails >= 7
    else
      preloader.new.preload(records, @association_name.to_sym)                       # Rails 6
    end
  end
end
