# frozen_string_literal: true

module Lighthouse
  module GraphQL
    module DataloaderSources
      class ModelLoader < ::GraphQL::Dataloader::Source
        def initialize(model_class)
          @model_class = model_class
        end

        # Keys are ids. GraphQL `ID` arguments arrive as strings while records
        # carry their column type (usually Integer), so match on the string form.
        def fetch(keys)
          records = @model_class.where(id: keys).index_by { |record| record.id.to_s }
          keys.map { |k| records[k.to_s] }
        end
      end
    end
  end
end
