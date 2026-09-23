# frozen_string_literal: true

module Lighthouse
  module GraphQL
    module DataloaderSources
      class AssociationLoader < ::GraphQL::Dataloader::Source
        def initialize(model_class, association_name)
          @model_class = model_class
          @association_name = association_name.to_s
        end

        # keys: array of parent objects
        def fetch(keys)
          keys.map do |parent|
            if parent.respond_to?(@association_name)
              parent.public_send(@association_name)
            else
              nil
            end
          end
        end
      end
    end
  end
end
