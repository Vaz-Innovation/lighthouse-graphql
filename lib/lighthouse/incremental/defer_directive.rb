# frozen_string_literal: true

# @defer, as the specification draft has it (graphql-spec PR #1110): on a
# fragment, it asks for the fragment's fields after the rest of the response.
#
# It is a graphql-ruby execution directive: `include?` decides whether the
# runtime runs the fragment where it stands. With an Incremental::State in the
# context (Run puts one there when the client accepts a streamed response), the
# fragment is left out and kept in the State, to run once the first response is
# out. Without one, `include?` is true and the directive does nothing: a server
# may ignore @defer, and answers the whole response at once.
#
# Document stamps each @defer with the number of its fragment, as the `label`
# ("lh:3"; the label the client gave is kept in the State), which is how
# `include?` learns which fragment it is asked about.
class Lighthouse::GraphQL::Incremental::DeferDirective < GraphQL::Schema::Directive
  graphql_name 'defer'
  description 'Deliver the fields of a fragment after the rest of the response, when the client accepts a streamed response (experimental).'
  locations ::GraphQL::Schema::Directive::FRAGMENT_SPREAD, ::GraphQL::Schema::Directive::INLINE_FRAGMENT

  argument :if, ::GraphQL::Types::Boolean, required: true, default_value: true,
                                           description: 'Defer the fragment only when true.'
  argument :label, ::GraphQL::Types::String, required: false,
                                             description: 'Names the fragment in the streamed response. Unique in the document, and not a variable.'

  class << self
    def include?(object, arguments, context)
      state = context[Lighthouse::GraphQL::Incremental::State::CONTEXT_KEY]
      return true if state.nil? || arguments[:if] == false

      id = Lighthouse::GraphQL::Incremental::State.stamped_id(arguments[:label])
      id.nil? || !state.defer(id, object, context)
    end
  end
end
