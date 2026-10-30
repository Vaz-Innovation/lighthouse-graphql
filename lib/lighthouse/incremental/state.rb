# frozen_string_literal: true

# What one request's incremental delivery knows while it runs, kept in the
# context (CONTEXT_KEY): the deferred fragments of its document, the objects
# @defer found them pending on, and whether they may still be deferred.
#
# @defer asks `defer` for every object a deferred fragment would run on. The
# fragment does not run there: the object, with its path in the response, is
# kept as a Pending, and Run executes the fragment on it once the first
# response is out (GraphQL::Query#run_partials).
class Lighthouse::GraphQL::Incremental::State
  CONTEXT_KEY = :lighthouse_incremental

  # What Document sets the `label` of each @defer and @stream to: this, the fragment's
  # number, and the label the client gave, if it did ("lh:3", "lh:4:details").
  STAMP = 'lh:'

  def self.stamp(id, label)
    label ? "#{STAMP}#{id}:#{label}" : "#{STAMP}#{id}"
  end

  def self.stamped_id(label)
    label.delete_prefix(STAMP).to_i if label.is_a?(String) && label.start_with?(STAMP)
  end

  # The label the client gave a stamped directive (nil when it gave none).
  def self.given_label(stamped)
    stamped.delete_prefix(STAMP).split(':', 2)[1]
  end

  # A deferred fragment, or a streamed field (`stream`), of the document, as Document
  # found it. For a fragment, `node` holds the selections it runs (an InlineFragment
  # without type or directives); `condition` is the name of its type condition,
  # `parent_type` the name of the type the selection set it sits in has (what an
  # untyped fragment runs on).
  Fragment = Struct.new(:id, :node, :condition, :parent_type, :label, :stream, keyword_init: true) do
    def type_name = condition || parent_type

    # An object of the type a typed fragment names, or of a type that is
    # possible for it: a fragment on `Admin` under a list of `User` interface
    # items only runs on the admins.
    def applies_to?(object, context)
      return true if condition.nil?

      type = context.query.types.type(condition)
      !type.nil? && context.query.types.possible_types(type).include?(object.class)
    end
  end

  # A fragment waiting to run on `object` (the application value, not
  # graphql-ruby's wrapper), at `path` of the response. `id` is its string id
  # in `pending` entries, set once announced. For a streamed field, `object` is
  # the items the first response left out, which start at index `offset` of the list.
  Pending = Struct.new(:fragment, :object, :path, :id, :offset, keyword_init: true)

  attr_reader :fragments

  # false once a limit is reached (Run): every fragment then runs where it stands,
  # and every list is answered whole, as PHP Lighthouse's `shouldDeferFurther`.
  attr_accessor :deferring

  def initialize(fragments)
    @fragments = fragments
    @deferring = true
    # The Pending fragments found, by the query (the operation's, or a Partial) that found them.
    @recorded = {}.compare_by_identity
  end

  # true when the fragment `fragment_id` is deferred on `object`: the caller
  # leaves it out of the response. false when it runs where it stands (it does
  # not apply to the object, or nothing is deferred any more).
  def defer(fragment_id, object, context)
    fragment = @fragments[fragment_id]
    return false unless @deferring && fragment&.applies_to?(object, context)

    record(context, Pending.new(fragment: fragment, object: object.object, path: context[:current_path]))
  end

  # true when the list field of fragment `fragment_id` streams: `items` (what is
  # left of the list, after the `offset` the first response has) will follow.
  def stream(fragment_id, items, offset, context)
    return false unless @deferring

    record(context, Pending.new(fragment: @fragments[fragment_id], object: items, path: context[:current_path], offset: offset))
  end

  # The Pending fragments `query` found (the GraphQL::Query of the first pass, or the
  # GraphQL::Query::Partial of a later one), forgotten once drained.
  def drain(query)
    @recorded.delete(query) || []
  end

  private

  def record(context, pending)
    (@recorded[context.query] ||= []) << pending
    true
  end
end
