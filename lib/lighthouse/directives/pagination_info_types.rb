# frozen_string_literal: true

# SDL of the info types the generated paginator and connection types report
# through (`paginatorInfo: PaginatorInfo!`, `pageInfo: PageInfo!`), keyed by
# type name. Each is emitted once by PaginationManipulator, and only when the
# schema does not declare it itself.
module Lighthouse::GraphQL::Directives::PaginationInfoTypes
  DEFINITIONS = {
    'PaginatorInfo' => <<~GRAPHQL,
      "Information about pagination using a fully featured paginator."
      type PaginatorInfo {
        "Number of items in the current page."
        count: Int!
        "Index of the current page."
        currentPage: Int!
        "Index of the first item in the current page."
        firstItem: Int
        "Are there more pages after this one?"
        hasMorePages: Boolean!
        "Index of the last item in the current page."
        lastItem: Int
        "Index of the last available page."
        lastPage: Int!
        "Number of items per page."
        perPage: Int!
        "Number of total available items."
        total: Int!
      }
    GRAPHQL
    'SimplePaginatorInfo' => <<~GRAPHQL,
      "Information about pagination using a simple paginator."
      type SimplePaginatorInfo {
        "Number of items in the current page."
        count: Int!
        "Index of the current page."
        currentPage: Int!
        "Index of the first item in the current page."
        firstItem: Int
        "Index of the last item in the current page."
        lastItem: Int
        "Number of items per page."
        perPage: Int!
        "Are there more pages after this one?"
        hasMorePages: Boolean!
      }
    GRAPHQL
    'PageInfo' => <<~GRAPHQL
      "Information about pagination using a Relay style cursor connection."
      type PageInfo {
        "When paginating forwards, are there more items?"
        hasNextPage: Boolean!
        "When paginating backwards, are there more items?"
        hasPreviousPage: Boolean!
        "The cursor to continue paginating backwards."
        startCursor: String
        "The cursor to continue paginating forwards."
        endCursor: String
        "Total number of nodes in the paginated connection."
        total: Int!
        "Number of nodes in the current page."
        count: Int!
        "Index of the current page."
        currentPage: Int!
        "Index of the last available page."
        lastPage: Int!
      }
    GRAPHQL
  }.freeze
end
