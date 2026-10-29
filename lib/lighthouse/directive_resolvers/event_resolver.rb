# frozen_string_literal: true

require_relative 'base'

# @event(dispatch: "OrderShipped") — dispatch an event once the field has
# resolved: the class is built with the resolved value and handed to
# Lighthouse::Events.dispatch. The value is returned unchanged; if the field
# raises, nothing is dispatched. Repeatable: each @event dispatches its own.
#
# The class is looked up in Config.namespaces[:events] (a fully-qualified
# name is used as-is); a name that is no class fails the schema build.
class Lighthouse::GraphQL::DirectiveResolvers::EventDirectiveResolver < Lighthouse::GraphQL::DirectiveResolvers::BaseDirectiveResolver
  def self.directive_name = 'event'

  def self.definition
    <<~GRAPHQL.chomp
      """
      Dispatch an event once the field has resolved. The event is built with the resolved value,
      which is returned unchanged. Nothing is dispatched if the field fails.
      """
      directive @event(
        "The event class, looked up in Config.namespaces[:events]. A fully-qualified name is used as-is."
        dispatch: String!
      ) repeatable on FIELD_DEFINITION
    GRAPHQL
  end

  def define_resolver(target_type_class)
    name = directive_arg('dispatch')
    self.class.event_class(name, "#{@type_def.graphql_name}.#{@field_def.name}")
    inner = capture_inner(target_type_class)

    install(target_type_class, lambda do |obj, args, ctx|
      result = inner.call(obj, args, ctx)
      Lighthouse::Events.dispatch(Lighthouse::GraphQL::DirectiveResolvers::EventDirectiveResolver.event_class(name).new(result))
      result
    end)
  end

  # The event class `name` names. Looked up on every dispatch, so a reloaded
  # class is the one built.
  def self.event_class(name, location = nil)
    klass = Lighthouse::Support::ModelResolver.constantize(name, namespaces: Lighthouse::Config.namespaces[:events])
    return klass if klass.respond_to?(:new)

    raise Lighthouse::DefinitionError,
          "@event on #{location}: no event class #{name} (looked in #{Lighthouse::Config.namespaces[:events].join(', ')})"
  end
end
