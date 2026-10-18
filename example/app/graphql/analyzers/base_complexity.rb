# frozen_string_literal: true

# What every analyzer that prices a field shares: a graphql-ruby QueryComplexity
# with Lighthouse's concern, whose `complexity` is the cost of the fields naming the
# analyzer in @complexity(resolver:). A subclass declares only its `complexity`, and
# a `result` when it should also act on the whole query.
class Analyzers::BaseComplexity < GraphQL::Analysis::QueryComplexity
  include Lighthouse::GraphQL::ComplexityAnalyzer
end
