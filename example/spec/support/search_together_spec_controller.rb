# The app's endpoint, serving the schema a search spec builds (spec/requests/graphql/search_spec.rb).
class SearchTogetherSpecController < GraphqlController
  cattr_accessor :schema

  lighthouse_schema { self.class.schema }
end
