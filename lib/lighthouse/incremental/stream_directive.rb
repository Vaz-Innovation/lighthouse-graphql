# frozen_string_literal: true

# @stream, as the specification draft has it (graphql-spec PR #1110): on a list
# field, it asks for the first `initialCount` items at once and the rest after
# the response.
#
# StreamTrace, the trace module Defer.use adds to the schema, does the work: a
# field resolver returns the whole list, and StreamTrace cuts it where the
# directive says. graphql-ruby calls `resolve` around the resolution of a field
# that carries the directive, and of no other: it hands the directive's arguments
# to that field's `execute_field` through the fiber-local MARK, which StreamTrace
# takes before the field's resolver runs.
class Lighthouse::GraphQL::Incremental::StreamDirective < GraphQL::Schema::Directive
  MARK = :lighthouse_stream

  graphql_name 'stream'
  description 'Deliver the items of a list after the first `initialCount`, when the client accepts a streamed response (experimental).'
  locations ::GraphQL::Schema::Directive::FIELD

  argument :if, ::GraphQL::Types::Boolean, required: true, default_value: true,
                                           description: 'Stream the list only when true.'
  argument :label, ::GraphQL::Types::String, required: false,
                                             description: 'Names the stream in the streamed response. Unique in the document, and not a variable.'
  argument :initial_count, ::GraphQL::Types::Int, required: true, default_value: 0,
                                                  description: 'How many items come with the first response.'

  class << self
    def resolve(_object, arguments, context)
      return yield if arguments[:if] == false

      previous = Thread.current[MARK]
      Thread.current[MARK] = [context[:current_field], arguments]
      begin
        yield
      ensure
        Thread.current[MARK] = previous
      end
    end
  end
end
