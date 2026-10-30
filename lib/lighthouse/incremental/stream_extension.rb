# frozen_string_literal: true

# The graphql-ruby field extension behind @stream (Defer.use adds it to the
# schema's list fields). Once the resolver has answered, it cuts the list the
# field's @stream asks to cut: with an Incremental::State in the context (which
# knows the directive by its arguments, see State), it
# returns the first `initialCount` items, and keeps the rest in the State to
# follow (Run). The field's resolver, directives included, runs once, for the
# whole list; the items' own selections run for the items that stay, here, and for
# those that follow, in the pass that delivers them.
#
# A field without @stream pays for the extension's two calls and one fiber-local
# read, and nothing more: StreamDirective, which graphql-ruby only runs around a
# field that carries it, leaves the directive's arguments in StreamDirective::MARK
# for the field's extension to take, so no field needs its AST node (an `extras`
# that would copy the arguments of every list field resolved).
class Lighthouse::GraphQL::Incremental::StreamExtension < GraphQL::Schema::FieldExtension
  State = Lighthouse::GraphQL::Incremental::State
  MARK = Lighthouse::GraphQL::Incremental::StreamDirective::MARK
  NEGATIVE = 'The initialCount of @stream must not be negative.'

  # The arguments of the field's @stream, if StreamDirective marked this field, go on as the memo.
  def resolve(object:, arguments:, **)
    mark = Thread.current[MARK]
    return yield(object, arguments) unless mark && mark.first.equal?(field)

    Thread.current[MARK] = nil
    yield(object, arguments, mark.last)
  end

  # A negative initialCount is a field error (the draft's CompleteValue), whether the
  # response is streamed or not.
  def after_resolve(object:, value:, context:, memo:, **)
    return value unless memo && list?(value)
    return ::GraphQL::ExecutionError.new(NEGATIVE) if memo[:initial_count].negative?

    state = context[State::CONTEXT_KEY]
    state ? cut(value.to_a, object, memo, state, context) : value
  end

  private

  # A list the resolver answered; nil (a nullable list's null) answers to `to_a` too, and stays null.
  def list?(value)
    !value.nil? && value.respond_to?(:to_a) && !value.is_a?(Hash)
  end

  # The first `initialCount` items, with the rest kept in the State; the list as it is when there is no rest to stream.
  def cut(items, object, arguments, state, context)
    initial = arguments[:initial_count]
    return items if items.size <= initial

    type = field.type.non_null? ? field.type.of_type : field.type
    state.stream(object, arguments, items.drop(initial), context, type) ? items.first(initial) : items
  end
end
