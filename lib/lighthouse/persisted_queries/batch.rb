# frozen_string_literal: true

# A batch of operations (a JSON array in the request) run in one go through
# `schema.multiplex`: the query each operation (a Hash of query, extensions,
# variables, operation_name and context) names, resolved as PersistedQueries.execute
# does. Answers one result per operation, in order; an operation the protocol
# rejects gets its ready-to-render error Hash. Dispatches the Operation(s)
# events with the Arrays of operations and results.
module Lighthouse::GraphQL::PersistedQueries::Batch
  module_function

  def run(schema, operations, **options)
    operations = operations.map { |operation| operation.to_h.symbolize_keys }
    Lighthouse::Events.dispatch(Lighthouse::Events::StartOperationOrOperations.new(operations))
    rejected = {}
    queries = operations.each_with_index.filter_map { |operation, index| query(operation, index, rejected) }
    ran = schema.multiplex(queries, **options).to_a
    results = operations.each_index.map { |index| rejected.fetch(index) { ran.shift } }
    Lighthouse::Events.dispatch(Lighthouse::Events::EndOperationOrOperations.new(results))
    results
  end

  # One operation as `schema.multiplex` takes it; a rejected one is noted
  # under its index instead.
  def query(operation, index, rejected)
    {
      query: Lighthouse::GraphQL::PersistedQueries.resolve(operation[:query], operation[:extensions]),
      variables: operation[:variables] || {}, operation_name: operation[:operation_name], context: operation[:context] || {}
    }
  rescue Lighthouse::GraphQL::PersistedQueries::Error => e
    rejected[index] = e.to_h
    nil
  end
end
