# frozen_string_literal: true

# @stream, as the specification draft has it (graphql-spec PR #1110): on a list
# field, it asks for the first `initialCount` items at once and the rest after
# the response.
#
# The directive only declares the arguments; StreamExtension, which Defer.use puts
# on the schema's list fields, does the work: a field resolver returns the whole
# list, and the extension cuts it where the directive says.
class Lighthouse::GraphQL::Incremental::StreamDirective < GraphQL::Schema::Directive
  graphql_name 'stream'
  description 'Deliver the items of a list after the first `initialCount`, when the client accepts a streamed response (experimental).'
  locations GraphQL::Schema::Directive::FIELD

  argument :if, GraphQL::Types::Boolean, required: true, default_value: true,
                                         description: 'Stream the list only when true.'
  argument :label, GraphQL::Types::String, required: false,
                                           description: 'Names the stream in the streamed response. Unique in the document, and not a variable.'
  argument :initial_count, GraphQL::Types::Int, required: true, default_value: 0,
                                                description: 'How many items come with the first response.'
end
