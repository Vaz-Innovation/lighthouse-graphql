# frozen_string_literal: true

# The graphql-ruby trace module behind @stream: Defer.use adds it to the schema
# that uses the plugin (to it and its subclasses, and to no other schema built on
# the same types), so every list field of that schema can stream, whenever it was
# defined, and no field is changed.
#
# StreamDirective, which graphql-ruby runs around a field that carries @stream,
# and only then, leaves the directive's arguments in its fiber-local MARK; the
# field's `execute_field`, which runs inside it, takes them before the resolver
# runs. Once the resolver has answered (or its lazy value is synced), a negative
# initialCount is a field error (the draft's CompleteValue), streamed or not; with
# an Incremental::State in the context, the list keeps its first `initialCount`
# items, and the rest are kept in the State to follow (Run). A field without
# @stream costs one fiber-local read.
module Lighthouse::GraphQL::Incremental::StreamTrace
  MARK = Lighthouse::GraphQL::Incremental::StreamDirective::MARK
  NEGATIVE = 'The initialCount of @stream must not be negative.'

  def execute_field(field:, query:, object:, **options)
    mark = Thread.current[MARK]
    return super unless mark && mark.first.equal?(field)

    Thread.current[MARK] = nil
    result = super
    return Lighthouse::GraphQL::Incremental::StreamTrace.cut(result, mark.last, field, object, query) unless query.schema.lazy?(result)

    ((@lighthouse_streams ||= {}.compare_by_identity)[object] ||= {}.compare_by_identity)[field] = mark.last
    result
  end

  def execute_field_lazy(field:, query:, object:, **options)
    result = super
    arguments = @lighthouse_streams&.[](object)&.delete(field)
    arguments ? Lighthouse::GraphQL::Incremental::StreamTrace.cut(result, arguments, field, object, query) : result
  end

  # The value the field answers: a list's first `initialCount` items, with the rest kept in the
  # State; the list as it is when there is no rest to stream, or no State.
  def self.cut(value, arguments, field, object, query)
    return value unless list?(value)
    return ::GraphQL::ExecutionError.new(NEGATIVE) if arguments[:initial_count].negative?

    state = query.context[Lighthouse::GraphQL::Incremental::State::CONTEXT_KEY] or return value
    initial = arguments[:initial_count]
    items = value.to_a
    return items if items.size <= initial

    type = field.type.non_null? ? field.type.of_type : field.type
    state.stream(object, arguments, items.drop(initial), query.context, type) ? items.first(initial) : items
  end

  # A list the resolver answered; nil (a nullable list's null) answers to `to_a` too, and stays null.
  def self.list?(value)
    !value.nil? && value.respond_to?(:to_a) && !value.is_a?(Hash)
  end
end
