# frozen_string_literal: true

require 'active_support/concern'

# A concern for a graphql-ruby analyzer that @complexity(resolver:) names. Its
# one method, `complexity`, gives the fields naming the class their cost, as
# graphql-ruby's `complexity` gives a field or a GraphQL::Schema::Resolver one:
#
#   class Analyzers::TagPostsComplexity < GraphQL::Analysis::QueryComplexity
#     include Lighthouse::GraphQL::ComplexityAnalyzer
#
#     complexity ->(_context, _args, child_complexity) { 1 + (child_complexity * 25) }
#   end
#
# A number is added to the cost of the field's selection; a proc is called with
# (context, args, child_complexity) and returns the whole cost. Without
# `complexity`, the field costs what a bare @complexity gives.
#
# The class stays an analyzer, installed on the schema like any class @complexity
# names: a `result` of its own runs on every query, in graphql-ruby's analysis.
# Without one it only gives costs, and graphql-ruby skips it.
module Lighthouse::GraphQL::ComplexityAnalyzer
  extend ActiveSupport::Concern

  class_methods do
    # Set the cost (a number or a proc taking context, args and child_complexity),
    # or read it: the class's own, else its superclass's, else nil.
    def complexity(new_complexity = nil)
      return inherited_complexity if new_complexity.nil?

      unless new_complexity.is_a?(Numeric) || (new_complexity.is_a?(Proc) && new_complexity.parameters.size == 3)
        raise ArgumentError, "#{name}.complexity takes a number or a proc of (context, args, child_complexity), " \
                             "got #{new_complexity.inspect}"
      end

      @complexity = new_complexity
    end

    private

    def inherited_complexity
      return @complexity if defined?(@complexity)

      superclass.respond_to?(:complexity) ? superclass.complexity : nil
    end
  end

  # Run in graphql-ruby's analysis only when the class has a `result` of its own.
  def analyze?
    self.class.instance_method(:result).owner != Lighthouse::GraphQL::ComplexityAnalyzer && super
  end

  def result
    nil
  end
end
