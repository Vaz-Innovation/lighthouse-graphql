# frozen_string_literal: true

# The graphql-ruby field extension behind @stream (Defer.use adds it to the
# schema's list fields). It reads the field's @stream, stamped by Document, once
# the resolver has answered: with an Incremental::State in the context, it
# returns the first `initialCount` items, and keeps the rest in the State to
# follow (Run). The field's resolver, directives included, runs once, for the
# whole list; the items' own selections run for the items that stay, here, and for
# those that follow, in the pass that delivers them.
class Lighthouse::GraphQL::Incremental::StreamExtension < GraphQL::Schema::FieldExtension
  State = Lighthouse::GraphQL::Incremental::State
  NEGATIVE = 'The initialCount of @stream must not be negative.'

  extras [:ast_node]

  # The field's AST node goes on as the memo, for `after_resolve`.
  def resolve(object:, arguments:, **)
    yield(object, arguments, arguments[:ast_node])
  end

  # A negative initialCount is a field error (the draft's CompleteValue), whether the
  # response is streamed or not.
  def after_resolve(value:, context:, memo:, **)
    arguments = list?(value) && stream(memo, context)
    return value unless arguments
    return ::GraphQL::ExecutionError.new(NEGATIVE) if arguments[:initial_count].negative?

    state = context[State::CONTEXT_KEY]
    id = State.stamped_id(arguments[:label])
    state && id ? cut(value.to_a, id, arguments[:initial_count], state, context) : value
  end

  private

  # The arguments of the field's @stream, unless it has none or it is off.
  def stream(ast_node, context)
    directive = ast_node.directives.find { |node| node.name == 'stream' } or return nil
    arguments = context.query.arguments_for(directive, Lighthouse::GraphQL::Incremental::StreamDirective)
    arguments unless arguments[:if] == false
  end

  # A list the resolver answered; nil (a nullable list's null) answers to `to_a` too, and stays null.
  def list?(value)
    !value.nil? && value.respond_to?(:to_a) && !value.is_a?(Hash)
  end

  # The first `initial` items, with the rest kept in the State; the list as it is when there is no rest to stream.
  def cut(items, id, initial, state, context)
    return items if items.size <= initial

    state.stream(id, items.drop(initial), initial, context) ? items.first(initial) : items
  end
end
