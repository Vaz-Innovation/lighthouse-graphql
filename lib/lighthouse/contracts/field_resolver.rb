# frozen_string_literal: true

require_relative 'directive'

# A directive that provides the runtime resolver for a field, e.g. @all,
# @find, @paginate, @hasMany, @belongsTo, @field, @auth, @aggregate.
#
# During the resolution phase the SchemaGenerator instantiates the directive
# and installs its resolver onto the field. Legacy resolvers fulfil this via
# `#define_resolver(target_type)`; clean directives implement `#resolve_field`
# returning a `#call(obj, args, ctx)` lambda.
#
# A @search on the field needs its resolver to apply it, which Search::FieldCheck
# asks the class when the schema is built. By default a resolver applies none,
# and the @search is a schema error. A class opts in with class methods:
#
#   # It runs the field's argument filters, a relational search (pg_search) among
#   # them: BaseDirectiveResolver#apply_where_filters, or resolve_info.enhance_builder.
#   def self.applies_search? = true
#
#   # It also takes the records an engine outside the database (Searchkick)
#   # answers with, a Search::Result, on this field.
#   def self.takes_search_results?(type, field_def, directive, root_kind) = true
module Lighthouse::Contracts::FieldResolver
  include Lighthouse::Contracts::Directive

  # The defaults: no search applied, no search result taken.
  module SearchDefaults
    def applies_search? = false
    def takes_search_results?(_type, _field_def, _directive, _root_kind) = false
  end

  def self.included(base)
    super
    base.extend(SearchDefaults)
  end

  # Does the resolver class apply a search on its field? Not unless it says so,
  # whether or not it includes the contract (a duck-typed `define_resolver` class).
  def self.applies_search?(klass) = !!(klass.respond_to?(:applies_search?) && klass.applies_search?)

  # Does it take an engine's Search::Result on this field?
  def self.takes_search_results?(klass, type, field_def, directive, root_kind)
    !!(klass.respond_to?(:takes_search_results?) && klass.takes_search_results?(type, field_def, directive, root_kind))
  end
end
