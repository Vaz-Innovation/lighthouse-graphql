# frozen_string_literal: true

# The events Lighthouse dispatches, in the order a request meets them (see
# docs/events.md). All inherit Events::Event, so `moment` is there when a
# class says so.
module Lighthouse::Events
  # A request reached the controller. `request` is the Rack/Rails request.
  class StartRequest < Event
    attr_reader :request

    def initialize(request)
      super()
      @request = request
    end
  end

  # The operation(s) of a request were read, before they run: one Hash
  # (query, variables, operation_name, extensions) or, for a batch, an Array of them.
  class StartOperationOrOperations < Event
    attr_reader :operation_or_operations

    def initialize(operation_or_operations)
      super()
      @operation_or_operations = operation_or_operations
    end
  end

  # The schema is being built from `user_schema`, the SDL of the app. A
  # listener may return SDL (a String) to append to it.
  class BuildSchemaString < Event
    attr_reader :user_schema

    def initialize(user_schema)
      super()
      @user_schema = user_schema
    end
  end

  # The directive classes are being registered. A listener may return a
  # namespace (a Module or its name) or an Array of them; every directive class
  # under them is registered.
  class RegisterDirectiveNamespaces < Event
  end

  # The schema document was built and manipulated, before the schema is built
  # from it. graphql-ruby's nodes are immutable: a listener sets `document_ast`
  # to the document to build from.
  class ManipulateAST < Event
    attr_accessor :document_ast

    def initialize(document_ast)
      super()
      @document_ast = document_ast
    end
  end

  # A query is about to run. `query` is its parsed GraphQL::Language::Nodes::Document
  # (nil if it does not parse), `operation_name` the one the client gave.
  # Fires once per operation of a multiplex: in a batch, every StartExecution
  # comes before any EndExecution, as graphql-ruby runs the operations
  # together. `graphql_query` (the GraphQL::Query) is the one the operation's
  # EndExecution carries too, to pair them.
  class StartExecution < Event
    attr_reader :schema, :query, :variables, :operation_name, :context, :graphql_query

    # PHP Lighthouse's five, positional as there, then the query.
    def initialize(schema, query, variables, operation_name, context, graphql_query = nil) # rubocop:disable Metrics/ParameterLists
      super()
      @schema = schema
      @query = query
      @variables = variables
      @operation_name = operation_name
      @context = context
      @graphql_query = graphql_query
    end
  end

  # A query ran. A listener may return an Events::ExtensionsResponse (or an
  # Array of them), which is merged into the result's "extensions".
  # `query_complexity` is the query's complexity score, as graphql-ruby checks it
  # against max_complexity (see GraphQL::Complexity); nil for a query that
  # failed validation, which is never scored.
  class BuildExtensionsResponse < Event
    attr_reader :result, :query_complexity

    def initialize(result, query_complexity)
      super()
      @result = result
      @query_complexity = query_complexity
    end
  end

  # The result Hash ("data", "errors", "extensions") of a query, before it is
  # returned. A listener may change it in place, or set `result` to replace it.
  class ManipulateResult < Event
    attr_accessor :result

    def initialize(result)
      super()
      @result = result
    end
  end

  # A query ran and its result is final. `graphql_query` is the GraphQL::Query
  # its StartExecution carried; `operation_name` the operation that ran (nil
  # for an anonymous one), and `context` its context. PHP Lighthouse's carries
  # the result only, where a batch runs its operations one after the other.
  class EndExecution < Event
    attr_reader :result, :graphql_query

    def initialize(result, graphql_query = nil)
      super()
      @result = result
      @graphql_query = graphql_query
    end

    def operation_name = graphql_query&.selected_operation_name

    def context = graphql_query&.context
  end

  # The operation(s) ran: the result, or for a batch an Array of results.
  class EndOperationOrOperations < Event
    attr_reader :result_or_results

    def initialize(result_or_results)
      super()
      @result_or_results = result_or_results
    end
  end

  # The response is rendered. `response` is the Rack/Rails response.
  class EndRequest < Event
    attr_reader :response

    def initialize(response)
      super()
      @response = response
    end
  end

  # The schema is being validated (`rake lighthouse:validate_schema`).
  class ValidateSchema < Event
    attr_reader :schema

    def initialize(schema)
      super()
      @schema = schema
    end
  end

  # A key and its content for the "extensions" of a result, as a listener of
  # BuildExtensionsResponse returns it.
  class ExtensionsResponse
    attr_reader :key, :content

    def initialize(key, content)
      @key = key
      @content = content
    end
  end
end
