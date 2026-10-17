# frozen_string_literal: true

require_relative 'class_generator'

module Lighthouse
  module Generators
    # `rails generate lighthouse:builder PublishedPosts` — a query builder for
    # `@builder(class: "PublishedPosts")`.
    class BuilderGenerator < ClassGenerator
      desc 'Generate a query builder for @builder in app/graphql/builders.'

      private

      def kind = :builders

      def body
        <<~RUBY
          # Applied by @builder(class: "#{class_name}") before the field resolves:
          # receives the relation, the field's arguments and the GraphQL context, and
          # returns the relation to use.
          class #{class_basename}
            def self.call(relation, args, context)
              relation
            end
          end
        RUBY
      end

      def usage
        "Use it with @builder(class: \"#{class_name}\") on a field resolved by @all, @paginate, @first, @count or @aggregate."
      end
    end
  end
end
