# frozen_string_literal: true

require_relative 'base'

# @async — run a mutation in a queued job and answer `true` at once, as PHP
# Lighthouse's directive. What decides whether it may run does so in the
# request: @guard, the @can* family, @validator and the argument directives, so
# the client still gets their errors. What resolves it (@create, a Mutations::
# class, ...) runs in Lighthouse::GraphQL::AsyncMutationJob, through ActiveJob,
# with the arguments and the context values ActiveJob can serialize (records
# included, through GlobalID; a request or a file is left out).
#
#   type Mutation {
#     importFeed(url: String!): Boolean! @guard @async(queue: "imports")
#   }
#
# The field must be a Mutation field returning Boolean, and the schema a named
# constant, which the job looks up.
class Lighthouse::GraphQL::DirectiveResolvers::AsyncDirectiveResolver < Lighthouse::GraphQL::DirectiveResolvers::BaseDirectiveResolver
  def self.directive_name = 'async'

  def self.definition
    <<~GRAPHQL.chomp
      """
      Defer the execution of mutations to queued jobs.
      The field answers true once the job is queued.
      """
      directive @async(
        "The name of the queue to dispatch the job on."
        queue: String
      ) on FIELD_DEFINITION
    GRAPHQL
  end

  # What resolves `field` of `type` below @async, for the job to call.
  def self.inner(type, field)
    (type.instance_variable_get(:@lighthouse_async_inners) || {}).fetch(field.to_s) do
      raise Lighthouse::DefinitionError, "#{type.graphql_name}.#{field} has no @async."
    end
  end

  def define_resolver(target_type_class)
    validate!(target_type_class)
    inner = capture_inner(target_type_class)
    inners = target_type_class.instance_variable_get(:@lighthouse_async_inners) || {}
    target_type_class.instance_variable_set(:@lighthouse_async_inners, inners.merge(@field_def.name => inner))
    me = self

    install(target_type_class, lambda do |_obj, args, ctx|
      me.enqueue(target_type_class.graphql_name, args, ctx)
      true
    end)
  end

  def enqueue(type_name, args, ctx)
    schema_name = ctx.schema.name
    raise Lighthouse::DefinitionError, '@async needs a schema assigned to a constant (AppSchema = ...), for the job to find.' unless schema_name

    job = Lighthouse::GraphQL::AsyncMutationJob
    job = job.set(queue: directive_arg('queue')) if directive_arg('queue')
    job.perform_later(schema_name, type_name, @field_def.name, serializable(Lighthouse::Support::Arguments.plain(args)), context_values(ctx))
  end

  private

  def validate!(target_type_class)
    return if @opts[:root_kind] == :mutations && @field_def.type.unwrap.graphql_name == 'Boolean'

    raise Lighthouse::DefinitionError,
          "@async on #{target_type_class.graphql_name}.#{@field_def.name}: only a Mutation field returning Boolean can run in a job."
  end

  # The context's values ActiveJob can serialize.
  def context_values(ctx)
    values = ctx.respond_to?(:to_h) ? ctx.to_h : {}
    serializable(values.reject { |key, _| key.to_s.start_with?('graphql_', 'lighthouse_') || EXECUTION_KEYS.include?(key) })
  end

  # graphql-ruby's own context keys, which mean nothing outside the request.
  EXECUTION_KEYS = %i[current_path current_field current_object current_arguments].freeze

  def serializable(hash)
    hash.select do |_, value|
      ::ActiveJob::Arguments.serialize([value])
      true
    rescue StandardError
      false
    end.transform_keys(&:to_sym)
  end
end
