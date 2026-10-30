# frozen_string_literal: true

# The graphql-ruby trace module of incremental delivery: Defer.use adds it to the
# schema that uses the plugin (to it and its subclasses, in every trace mode, and
# to no other schema built on the same types), so it sees every field of that
# schema, whenever defined, and changes no field. It does two things.
#
# - @stream: StreamDirective, which graphql-ruby runs around a field that carries
#   @stream, and only then, leaves the directive's arguments in its fiber-local
#   MARK; the field's `execute_field`, which runs inside it, takes them before the
#   resolver runs. Once the resolver has answered (or its lazy value is synced, the
#   arguments kept by the field's AST node meanwhile), a negative initialCount is a
#   field error (the draft's CompleteValue), streamed or not; with an
#   Incremental::State in the context, the list keeps its first `initialCount`
#   items, and the rest are kept in the State to follow (Run).
# - While a streamed response runs (Run puts its State in the fiber-local RUNNING),
#   it hands the State the objects its deferred fragments will need: those of the
#   object fields a fragment adds selections to, which the rest of the query
#   resolved (Plan, State#keep).
#
# A field of any other request costs two fiber-local reads.
module Lighthouse::GraphQL::Incremental::StreamTrace
  MARK = Lighthouse::GraphQL::Incremental::StreamDirective::MARK
  RUNNING = :lighthouse_incremental_state
  NEGATIVE = 'The initialCount of @stream must not be negative.'

  # Where a field resolved: what `done` needs of it.
  Site = Struct.new(:field, :query, :object, :ast_node)

  def execute_field(field:, query:, object:, ast_node:, **options)
    stream = Lighthouse::GraphQL::Incremental::StreamTrace.take(field)
    return super unless stream || Thread.current[RUNNING]

    result = super
    site = Site.new(field, query, object, ast_node)
    return Lighthouse::GraphQL::Incremental::StreamTrace.done(result, stream, site) unless query.schema.lazy?(result)

    ((@lighthouse_streams ||= {}.compare_by_identity)[object] ||= {}.compare_by_identity)[ast_node] = stream if stream
    result
  end

  def execute_field_lazy(field:, query:, object:, ast_node:, **options)
    result = super
    stream = @lighthouse_streams&.[](object)&.delete(ast_node)
    return result unless stream || Thread.current[RUNNING]

    Lighthouse::GraphQL::Incremental::StreamTrace.done(result, stream, Site.new(field, query, object, ast_node))
  end

  # The arguments of the @stream StreamDirective marked `field` with, taken.
  def self.take(field)
    mark = Thread.current[MARK]
    return nil unless mark && mark.first.equal?(field)

    Thread.current[MARK] = nil
    mark.last
  end

  # The value the field answers, cut where its @stream says; the State keeps it if it needs it.
  def self.done(value, stream, site)
    value = cut(value, stream, site) if stream
    Thread.current[RUNNING]&.keep(site.query, site.ast_node, value)
    value
  end

  # A list's first `initialCount` items, with the rest kept in the State; the list as it is when
  # there is no rest to stream, or no State.
  def self.cut(value, arguments, site)
    return value unless list?(value)
    return ::GraphQL::ExecutionError.new(NEGATIVE) if arguments[:initial_count].negative?

    state = site.query.context[Lighthouse::GraphQL::Incremental::State::CONTEXT_KEY] or return value
    initial = arguments[:initial_count]
    items = value.to_a
    return items if items.size <= initial

    state.stream(site.object, arguments, items.drop(initial), site.query.context, site.field) ? items.first(initial) : items
  end

  # A list the resolver answered; nil (a nullable list's null) answers to `to_a` too, and stays null.
  def self.list?(value)
    !value.nil? && value.respond_to?(:to_a) && !value.is_a?(Hash)
  end
end
