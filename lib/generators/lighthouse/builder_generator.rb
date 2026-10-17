# frozen_string_literal: true

require_relative 'class_generator'

# `rails generate lighthouse:builder PublishedPosts` — a query builder for
# `@builder(class: "PublishedPosts")`.
class Lighthouse::Generators::BuilderGenerator < Lighthouse::Generators::ClassGenerator
  desc 'Generate a query builder for @builder in app/graphql/builders.'

  private

  def kind = :builders

  def body
    <<~RUBY
      # Applied by @builder(class: "#{class_name}") before the field resolves:
      # receives the relation, the field's arguments and the GraphQL context, and
      # returns the relation to use. Its type is Lighthouse::_Builder.
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
