# frozen_string_literal: true

module Lighthouse
  module Support
    # Access to the query's GraphQL::Dataloader. graphql-ruby hands every query a
    # dataloader — a NullDataloader, whose sources refuse to run, when the schema
    # does not `use GraphQL::Dataloader` — so "is there one" needs this check.
    module Batching
      module_function

      def dataloader(context)
        dataloader = context.respond_to?(:dataloader) ? context.dataloader : nil
        return nil if dataloader.nil?
        return nil if defined?(::GraphQL::Dataloader::NullDataloader) && dataloader.is_a?(::GraphQL::Dataloader::NullDataloader)

        dataloader
      end
    end
  end
end
