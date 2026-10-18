# frozen_string_literal: true

# Central rule for translating GraphQL (camelCase) names into Rails
# (snake_case) attributes/columns, and for tolerant argument lookup.
#
# This is the single home for casing logic; every directive/resolver that
# needs to map a GraphQL name to a model attribute or DB column routes here
# instead of re-implementing `.underscore` fallbacks.
module Lighthouse::Support::Naming
  module_function

  # GraphQL field name -> Rails attribute/method name.
  # e.g. "customAttributes" -> "custom_attributes"
  #
  # This is the default field-reader rule and the basis for relation method
  # name derivation. The `@rename(attribute:)` directive is the explicit
  # override that bypasses this.
  def attribute(graphql_name)
    graphql_name.to_s.underscore
  end

  # Resolve a GraphQL "column" token (often an ALLCAPS enum key, or a raw
  # string) to a usable column name.
  #
  # NOTE: kept behavior-compatible with the historical `resolve_column_name`
  # so existing whereConditions queries are unaffected. Word-boundary
  # recovery for enum keys is handled separately by generating column enums
  # with explicit `@enum(value:)` mappings.
  def column(graphql_name, _relation = nil)
    name = graphql_name.to_s
    name = name.downcase if name == name.upcase
    name = name.tr('-', '_')
    name = name.underscore if name.include?(' ')
    name
  end

  # Fetch an argument value from a hash tolerant of camelCase/snake_case and
  # string/symbol keys. Replaces the ad-hoc `args[:x] || args['x'] || ...`
  # chains scattered across resolvers.
  def fetch_arg(args_h, name)
    return nil if args_h.nil?

    candidate_keys(name).each do |key|
      value = args_h[key]
      return value unless value.nil?
    end
    nil
  end

  def candidate_keys(name)
    raw = name.to_s
    snake = raw.underscore
    [raw.to_sym, raw, snake.to_sym, snake].uniq
  end
end
