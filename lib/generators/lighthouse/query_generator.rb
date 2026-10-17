# frozen_string_literal: true

require_relative 'class_generator'

module Lighthouse
  module Generators
    # `rails generate lighthouse:query LatestPosts` — a GraphQL::Schema::Resolver
    # that `Query.latestPosts` resolves to by convention.
    class QueryGenerator < ClassGenerator
      desc 'Generate a query class (GraphQL::Schema::Resolver) in app/graphql/queries.'

      private

      def kind = :queries

      def body
        <<~RUBY
          # Resolves Query.#{class_basename.camelize(:lower)}. Keyword arguments are the field's
          # arguments in snake_case; `object` and `context` are available.
          class #{class_basename} < GraphQL::Schema::Resolver
            def resolve(**args)
              raise NotImplementedError
            end
          end
        RUBY
      end

      def usage
        "Query.#{class_basename.camelize(:lower)} resolves to #{full_class_name} — add the field to your SDL without a resolving directive."
      end
    end
  end
end
