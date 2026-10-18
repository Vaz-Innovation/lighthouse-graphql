# frozen_string_literal: true

require 'active_job'

# Runs what resolves an @async mutation field, from a queue. Loaded on first
# use — the activejob gem is optional — so it is autoloaded, as BroadcastJob.
# The schema is passed by name; the field's resolver runs with the arguments
# and context values the request serialized, inside the schema's Dataloader.
class Lighthouse::GraphQL::AsyncMutationJob < ActiveJob::Base # rubocop:disable Rails/ApplicationJob
  def perform(schema_name, type_name, field_name, arguments, context_values)
    schema = schema_name.constantize
    type = schema.get_type(type_name)
    inner = Lighthouse::GraphQL::DirectiveResolvers::AsyncDirectiveResolver.inner(type, field_name)
    context = ::GraphQL::Query.new(schema, '{ __typename }', context: context_values.merge(lighthouse_async: true)).context
    context.dataloader.run_isolated { inner.call(nil, arguments.transform_keys(&:to_sym), context) }
  end
end
