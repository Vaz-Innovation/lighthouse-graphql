# frozen_string_literal: true

# Resolves a class name string (from a directive argument such as
# `@field(resolver: "Resolvers::ContactPerson")` or `@all(model: "Contact")`)
# into an actual constant.
#
# The list of namespaces to try is configurable via
# `Lighthouse::Config.resolver_namespaces`, so the library does not need to
# know any app-specific namespace. This is a key seam for extracting the
# library into a standalone gem.
module Lighthouse::Support::ModelResolver
  module_function

  DEFAULT_NAMESPACES = ['App::Graphql'].freeze

  # The suffix of a type Lighthouse generates for @paginate: PostPaginator, PostSimplePaginator, PostConnection.
  PAGINATION_SUFFIX = /(SimplePaginator|Paginator|Connection)\z/

  # The name of the model a directive on a field acts on: the directive's own
  # `model:`, else the `model:` of another directive on the field
  # (`@count(model: "Post") @canQuery`), else the field's return type without a
  # generated Paginator/Connection suffix. `directive_node` nil: the field's.
  def field_model_name(field_def, directive_node = nil)
    Lighthouse::Support::DirectiveArgs.literal(directive_node, 'model') ||
      (field_def.ast_node&.directives || []).filter_map { |d| Lighthouse::Support::DirectiveArgs.literal(d, 'model') }.first ||
      field_def.type.unwrap.graphql_name.sub(PAGINATION_SUFFIX, '')
  end

  # Is `value` an Active Record model class (not ActiveRecord::Base itself)?
  def model?(value)
    !!(defined?(::ActiveRecord::Base) && value.is_a?(Class) && value < ::ActiveRecord::Base)
  end

  # The Active Record model a class, or a class name, names; nil for anything else.
  def model_class(name_or_class)
    model = name_or_class.is_a?(Class) ? name_or_class : constantize(name_or_class)
    model if model?(model)
  end

  def namespaces
    if defined?(Lighthouse::Config) &&
       Lighthouse::Config.respond_to?(:resolver_namespaces) &&
       Lighthouse::Config.resolver_namespaces
      Array(Lighthouse::Config.resolver_namespaces)
    else
      DEFAULT_NAMESPACES
    end
  end

  # `namespaces:` overrides the configured resolver_namespaces, e.g. with
  # Config.namespaces[:builders] to look a builder class up.
  # `fallback: false` skips the bare name, so `Resolvers::User` is never
  # mistaken for the `User` model. `nested: true` tries the namespaces before a
  # name that already contains `::` too, so `Feeds::Home` is found as
  # `Resolvers::Feeds::Home`; otherwise such a name is used as-is.
  def constantize(name, namespaces: self.namespaces, fallback: true, nested: false)
    return nil unless name

    raw = name.to_s.strip
    return nil if raw.empty?

    candidates_for(raw, namespaces, fallback: fallback, nested: nested).each do |candidate|
      klass = try_constantize(candidate)
      return klass if klass
    end

    nil
  end

  def candidates_for(raw, namespaces = self.namespaces, fallback: true, nested: false)
    if raw.include?('::') && !nested
      [raw]
    else
      Array(namespaces).map { |ns| "#{ns}::#{raw}" } + (fallback ? [raw] : [])
    end
  end

  def try_constantize(candidate)
    ActiveSupport::Dependencies.constantize(candidate)
  rescue NameError, LoadError
    begin
      Object.const_get(candidate)
    rescue NameError
      nil
    end
  end
end
