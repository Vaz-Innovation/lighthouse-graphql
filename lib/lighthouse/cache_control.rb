# frozen_string_literal: true

# @cacheControl — compute the HTTP Cache-Control header a response may carry
# from the fields a query selects, as PHP Lighthouse (after Apollo) does:
#
# - max-age is the lowest maxAge among the contributing fields; 0 means
#   `no-cache`.
# - The response is `private` if any selected field's scope is PRIVATE.
# - Defaults: a root field is maxAge 0 and PRIVATE; any other field returning
#   an object, interface or union is maxAge 0 unless its type carries
#   @cacheControl; scalar fields inherit their parent and do not contribute.
#   A directive on the field wins over one on its type, and its omitted
#   arguments take the directive defaults (maxAge 0, PUBLIC).
# - `inheritMaxAge: true` uses the parent field's maxAge.
# - A mutation is never cacheable.
#
# The schema runs Analyzer on every query when its SDL uses @cacheControl;
# read the result with CacheControl.header(result) and set it on the
# response (see `apply`).
module Lighthouse::GraphQL::CacheControl
  # Arguments with a default are nullable, not `Type! = default` as in PHP: graphql-ruby
  # 2.5 does not fill in a directive argument's default, so a non-null one would be
  # refused wherever it is left out. Left out or null, it takes its default.
  DEFINITION = 'directive @cacheControl(maxAge: Int = 0, scope: CacheControlScope = PUBLIC, ' \
               'inheritMaxAge: Boolean = false) on FIELD_DEFINITION | OBJECT | INTERFACE | UNION'

  TYPE_DEFINITIONS = {
    'CacheControlScope' => <<~GRAPHQL.chomp
      "Who a cached response may be shared with."
      enum CacheControlScope {
        "The same for every user: shared caches (CDNs, proxies) may store it."
        PUBLIC
        "Specific to the user: only the user's own client may store it."
        PRIVATE
      }
    GRAPHQL
  }.freeze

  CONTEXT_KEY = :lighthouse_cache_control

  module_function

  # The Cache-Control value for an executed query (a GraphQL::Query::Result
  # or GraphQL::Query), or nil when the schema does not use @cacheControl.
  def header(result)
    query = result.respond_to?(:query) ? result.query : result
    query.respond_to?(:context) ? query.context[CONTEXT_KEY] : nil
  end

  # Set the header on a Rails (or Rack) response; a no-op without one.
  def apply(response, result)
    value = header(result)
    response.headers['Cache-Control'] = value if value
    value
  end

  def to_header(max_age, private_scope)
    visibility = private_scope ? 'private' : 'public'
    max_age.positive? ? "max-age=#{max_age}, #{visibility}" : "no-cache#{', private' if private_scope}"
  end

  class Analyzer < ::GraphQL::Analysis::Analyzer
    def initialize(subject)
      super
      @parents = []
      @max_age = nil
      @private = false
    end

    def on_enter_field(node, _parent, visitor)
      field = visitor.field_definition
      return @parents.push(@parents.last) if field.nil? || visitor.skipping?

      max_age, scope = hint_for(field)
      unless max_age.nil?
        @max_age = [@max_age, max_age].compact.min
        @private ||= scope == 'PRIVATE'
      end
      @parents.push(max_age.nil? ? @parents.last : max_age)
      node
    end

    def on_leave_field(_node, _parent, _visitor)
      @parents.pop
    end

    def result
      value =
        if query.mutation?
          'no-cache'
        else
          Lighthouse::GraphQL::CacheControl.to_header(@max_age || 0, @private)
        end
      query.context[CONTEXT_KEY] = value
    end

    private

    def root?
      @parents.empty?
    end

    # [maxAge, scope] the field contributes, or [nil, nil] to inherit.
    def hint_for(field)
      directive = cache_control(field.ast_node)
      return from_directive(directive) if directive
      return [0, 'PRIVATE'] if root?

      return_type = field.type.unwrap
      return [nil, nil] if return_type.kind.leaf?

      type_directive = cache_control(return_type.ast_node)
      type_directive ? from_directive(type_directive) : [0, 'PUBLIC']
    end

    def from_directive(directive)
      scope = Lighthouse::Support::DirectiveArgs.literal(directive, 'scope') || 'PUBLIC'
      if Lighthouse::Support::DirectiveArgs.literal(directive, 'inheritMaxAge')
        [@parents.last || 0, scope]
      else
        [Lighthouse::Support::DirectiveArgs.literal(directive, 'maxAge') || 0, scope]
      end
    end

    def cache_control(ast_node)
      ast_node&.directives&.find { |d| d.name == 'cacheControl' }
    end
  end
end
