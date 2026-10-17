# frozen_string_literal: true

# @feature — include a field or an object type in the schema depending on a
# feature flag (PHP Lighthouse's Laravel Pennant integration, here backed by
# Flipper).
#
# Flags are per request and per actor while the schema is built once, so the
# element is not removed from the schema: it is hidden through graphql-ruby's
# per-query visibility. Its `visible?(context)` answers whether the flag's
# state matches `when` (ACTIVE by default). A hidden field disappears from
# introspection and a query selecting it fails validation, as if the SDL did
# not declare it; the fields returning a hidden type are hidden with it.
#
# The state is read through Config.feature_checker for the actor of
# Config.feature_actor, at most once per feature and query (memoized in the
# query's context), however many times graphql-ruby asks.
#
# Printing the schema (`to_definition`) is a query of its own: it shows the
# features as they stand with no actor. Only graphql-ruby's own null context
# (preloading a visibility profile) hides nothing.
module Lighthouse::GraphQL::FeatureDirective
  # Arguments with a default are nullable, not `Type! = default` as in PHP: graphql-ruby
  # 2.5 does not fill in a directive argument's default, so a non-null one would be
  # refused wherever it is left out. Left out or null, it takes its default.
  DEFINITION = 'directive @feature(name: String!, when: FeatureState = ACTIVE) on FIELD_DEFINITION | OBJECT'

  TYPE_DEFINITIONS = {
    'FeatureState' => <<~GRAPHQL.chomp
      "Options for the `when` argument of `@feature`."
      enum FeatureState {
        "Indicates an active feature."
        ACTIVE
        "Indicates an inactive feature."
        INACTIVE
      }
    GRAPHQL
  }.freeze

  STATES = %w[ACTIVE INACTIVE].freeze
  CONTEXT_KEY = :lighthouse_features

  module_function

  # Config.feature_checker's default: ask Flipper.
  def default_checker
    lambda do |name, actor, _context|
      raise 'Lighthouse: configure `Config.feature_checker` to use @feature (Flipper not detected).' unless defined?(::Flipper)

      ::Flipper.enabled?(name.to_sym, actor)
    end
  end

  # Hide the types and fields of the schema that carry @feature.
  def apply(schema)
    used = false
    schema.types.each_value do |type|
      next unless type.kind.object? || type.kind.interface?

      used |= hide_type(type)
      type.fields.each_value { |field| used |= hide_field(type, field) }
    end
    silence_visibility_warning(schema) if used
    schema
  end

  # Is the feature's state the one @feature asks for, in this query?
  def visible?(name, state, context)
    return true if context.nil? || context.is_a?(::GraphQL::Query::NullContext)

    active = features(context).fetch(name) do
      features(context)[name] = check(name, context)
    end
    (state == 'ACTIVE') == active
  end

  def check(name, context)
    actor = Lighthouse::Config.feature_actor.call(context)
    Lighthouse::Config.feature_checker.call(name, actor, context) ? true : false
  end

  def features(context)
    context[CONTEXT_KEY] ||= {}
  end

  def hide_type(type)
    feature = requirement(type, type.graphql_name)
    return false unless feature

    name, state = feature
    original = type.method(:visible?)
    type.define_singleton_method(:visible?) do |context|
      original.call(context) && Lighthouse::GraphQL::FeatureDirective.visible?(name, state, context)
    end
    true
  end

  def hide_field(type, field)
    feature = requirement(field, "#{type.graphql_name}.#{field.name}")
    return false unless feature

    name, state = feature
    original = field.method(:visible?)
    field.define_singleton_method(:visible?) do |context|
      original.call(context) && Lighthouse::GraphQL::FeatureDirective.visible?(name, state, context)
    end
    true
  end

  # [feature name, required state] from the member's @feature, or nil.
  def requirement(member, path)
    node = member.ast_node&.directives&.find { |directive| directive.name == 'feature' }
    return unless node

    name = Lighthouse::Support::DirectiveArgs.literal(node, 'name').to_s
    raise Lighthouse::DefinitionError, "@feature on #{path} needs a feature `name`" if name.strip.empty?

    [name, required_state(node, path)]
  end

  def required_state(node, path)
    state = Lighthouse::Support::DirectiveArgs.literal(node, 'when') || 'ACTIVE'
    return state if STATES.include?(state)

    raise Lighthouse::DefinitionError, "@feature on #{path}: `when` must be ACTIVE or INACTIVE, got #{state}"
  end

  # graphql-ruby 2.6 warns, once per query, when a member is hidden and the
  # schema configured neither Visibility nor Warden. @feature is configured
  # on purpose: keep the schema on the default (Warden) unless it chose.
  def silence_visibility_warning(schema)
    chosen = [::GraphQL::Schema::Warden, (::GraphQL::Schema::Visibility if defined?(::GraphQL::Schema::Visibility))]
    return if schema.plugins.any? { |(plugin, _options)| chosen.include?(plugin) }
    return unless ::GraphQL::Schema::Warden.respond_to?(:use)

    schema.use(::GraphQL::Schema::Warden)
  end
end
