# frozen_string_literal: true

require_relative 'directive'

module Lighthouse
  module Contracts
    # A directive that provides the runtime resolver for a field, e.g. @all,
    # @find, @paginate, @hasMany, @belongsTo, @field, @auth, @aggregate.
    #
    # During the resolution phase the SchemaGenerator instantiates the directive
    # and installs its resolver onto the field. Legacy resolvers fulfil this via
    # `#define_resolver(target_type)`; clean directives implement `#resolve_field`
    # returning a `#call(obj, args, ctx)` lambda.
    module FieldResolver
      include Directive
    end
  end
end
