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

  extras [:ast_node]

  # The field's AST node goes on as the memo, for `after_resolve`.
  def resolve(object:, arguments:, **)
    yield(object, arguments, arguments[:ast_node])
  end

  def after_resolve(value:, context:, memo:, **)
    state = context[State::CONTEXT_KEY]
    directive = state && memo.directives.find { |node| node.name == 'stream' }
    return value unless directive && list?(value)

    arguments = context.query.arguments_for(directive, Lighthouse::GraphQL::Incremental::StreamDirective)
    id = State.stamped_id(arguments[:label])
    return value if id.nil? || arguments[:if] == false

    cut(value.to_a, id, [arguments[:initial_count], 0].max, state, context)
  end

  private

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
