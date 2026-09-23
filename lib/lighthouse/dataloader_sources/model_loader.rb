# frozen_string_literal: true

module Lighthouse
  module GraphQL
    module DataloaderSources
      class ModelLoader < ::GraphQL::Dataloader::Source
        def initialize(model_class)
          @model_class = model_class
        end

        # keys are ids
        def fetch(keys)
          records = @model_class.where(id: keys).index_by(&:id)
          keys.map { |k| records[k] }
        end
      end
    end
  end
end
