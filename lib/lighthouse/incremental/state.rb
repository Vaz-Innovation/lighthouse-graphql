# frozen_string_literal: true

require 'set'

# What one request's incremental delivery knows while it runs, kept in the
# context (CONTEXT_KEY): the client's Document, the fragments @defer and the
# lists @stream left pending, whether they may still be deferred, and the
# objects the fragments will need (StreamTrace keeps them).
#
# graphql-ruby asks DeferDirective.include? (and StreamDirective.resolve) with a
# directive's arguments, not its AST node. It takes those arguments from
# GraphQL::Query#arguments_for, which caches them per node and query: State maps
# the arguments object back to its node (`directive_for`), so the document is never
# rewritten to tell fragments apart. Arguments it does not know (were that cache to
# change) defer nothing: the fragment runs where it stands.
class Lighthouse::GraphQL::Incremental::State
  CONTEXT_KEY = :lighthouse_incremental
  MISSING = Object.new.freeze

  # A deferred fragment waiting to run on `object` (the application value, not graphql-ruby's
  # wrapper) of the object type `type`, at `path` of the response, found by a round's Plan in the
  # fragments `parents`; or, for the list `field` of `type`, the items of a streamed list that
  # the response left out (`object`), which start at index `offset` and run `selections`.
  # `node`: the fragment, or the @stream directive. `id` is its string id in `pending` entries,
  # set once announced.
  Pending = Struct.new(:node, :object, :type, :path, :label, :id, :offset, :selections, :field, :parents, keyword_init: true) do
    def stream? = !field.nil?

    # A stream's list type, nullable.
    def list_type = field.type.non_null? ? field.type.of_type : field.type
  end

  # false once a limit is reached (Run): every fragment then runs where it stands,
  # and every list is answered whole, as PHP Lighthouse's `shouldDeferFurther`.
  attr_accessor :deferring

  # The operation's GraphQL::Query, whose document State reads once it is parsed.
  attr_writer :query

  def initialize
    @deferring = true
    @recorded = {}.compare_by_identity
    @needed = Set.new
    @keys = Set.new
    @objects = {}
    @offsets = {}.compare_by_identity
  end

  # The client's document, as Document reads it.
  def document
    @document ||= Lighthouse::GraphQL::Incremental::Document.new(@query.schema, @query.document, @query.selected_operation)
  end

  # A stream's Partial (`query`) runs items of the list at `path`, counted from 0, that are at
  # `positions` of the response's list.
  def offset(query, path, positions)
    @offsets[query] = [path.size, positions]
  end

  # `path` as a path of the response: in a stream's Partial, its items' indices count from the
  # list's first item. Everything keyed or answered by path goes through it.
  def absolute(query, path)
    size, positions = @offsets[query]
    return path unless positions && path[size].is_a?(Integer)

    path.dup.tap { |copy| copy[size] = positions[copy[size]] }
  end

  # true when the fragment of the @defer whose `arguments` graphql-ruby evaluates is deferred
  # on `object` (graphql-ruby's wrapper): the caller leaves it out. false when it runs where
  # it stands. A fragment gathered twice on one object (spread twice) is deferred once.
  def defer(object, arguments, context)
    return false unless @deferring

    query = context.query
    fragment = directive_for(query, 'defer', arguments)&.then { |directive| document.owner(directive) }
    return false unless fragment && document.included?(fragment, query) && document.applies?(fragment, object.class, query)

    path = absolute(query, context[:current_path])
    found(query, Pending.new(node: fragment, object: object.object, type: object.class, path: path, label: arguments[:label]))
    true
  end

  # true when the list `field` whose @stream has `arguments` streams: `items` (what is left of
  # the list after the `initialCount` the first response has) will follow, with the selections
  # every declaration of the field gives them. `parent`: the wrapper of the field's object.
  def stream(parent, arguments, items, context, field)
    return false unless @deferring

    query = context.query
    directive = directive_for(query, 'stream', arguments) or return false
    path = absolute(query, context[:current_path])
    selections = document.merged(directive, path, parent.class, query, @deferring) or return false

    record(query, Pending.new(node: directive, object: items, type: parent.class, path: path, label: arguments[:label],
                              offset: arguments[:initial_count], selections: selections, field: field))
  end

  # A deferred fragment `query` found (or a round's Plan, as `defer` would have). Run announces a
  # fragment once at a path, however many times it is found there.
  def found(query, pending)
    need(pending.node, pending.path)
    record(query, pending)
  end

  # The pending fragments and lists `query` found (the GraphQL::Query of the first pass, a
  # GraphQL::Query::Partial of a later one, or a round's Plan), forgotten once drained, with
  # what State knew of `query`.
  def drain(query)
    @offsets.delete(query)
    @recorded.delete(query) || []
  end

  # StreamTrace: the value the field of `ast_node` resolved to in `query`, if a pending fragment
  # of this request may need it.
  def keep(query, ast_node, value)
    return unless @keys.include?(ast_node.alias || ast_node.name) && query.context[CONTEXT_KEY].equal?(self)

    path = query.context[:current_path]
    @objects[absolute(query, path)] = value if @needed.include?(path.grep_v(Integer))
  end

  # The value kept at `path`, or MISSING.
  def object_at(path) = @objects.fetch(path, MISSING)

  private

  # The directive node `arguments` were evaluated for, in `query`: the one directive of the
  # document with those values, evaluated once for the request; where several share them, the
  # one whose arguments `query` cached are these (Query#arguments_for). nil if none: whatever
  # it is, it then defers nothing.
  def directive_for(query, name, arguments)
    candidates = values[name][arguments.keyword_arguments] or return nil
    return candidates.first if candidates.one?

    definition = document.directive(name)
    candidates.find { |directive| query.arguments_for(directive, definition).equal?(arguments) }
  end

  # The document's @defer and @stream, by name, then by the values of their arguments.
  def values
    @values ||= %w[defer stream].to_h do |name|
      definition = document.directive(name)
      [name, document.directives(name).group_by { |directive| @query.arguments_for(directive, definition).keyword_arguments }]
    end
  end

  def record(query, pending)
    (@recorded[query] ||= []) << pending
    true
  end

  # The object fields a fragment selects, at any depth (as response paths without list indices
  # from its object): the round that runs it needs the objects those resolved to when the rest
  # of the query asked for them too.
  def need(fragment, path)
    base = path.grep_v(Integer)
    relative(fragment).each do |relative|
      @needed << (base + relative)
      @keys << relative.last
    end
  end

  # The fragment's object fields, walked once a request.
  def relative(fragment)
    (@relative ||= {}.compare_by_identity)[fragment] ||= object_fields(document.selections(fragment), [], [])
  end

  # `spreads`: the named fragments around the walk, which a cycle would spread again. A fragment
  # spread at several places is walked at each.
  def object_fields(selections, prefix, spreads)
    selections.flat_map do |selection|
      case selection
      when ::GraphQL::Language::Nodes::Field
        next [] if selection.selections.empty?

        own = prefix + [selection.alias || selection.name]
        [own] + object_fields(selection.selections, own, spreads)
      when ::GraphQL::Language::Nodes::FragmentSpread
        spreads.include?(selection.name) ? [] : object_fields(document.selections(selection), prefix, spreads + [selection.name])
      else object_fields(selection.selections, prefix, spreads)
      end
    end
  end
end
