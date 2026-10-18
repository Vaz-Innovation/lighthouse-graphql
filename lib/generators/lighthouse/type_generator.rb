# frozen_string_literal: true

require_relative 'class_generator'

# `rails generate lighthouse:type Post` — Types::PostType (a Types::BaseObject, so
# a GraphQL::Schema::Object) including Lighthouse::GraphQL::Type, whose methods
# resolve the fields of the SDL's Post type that have no resolving directive.
class Lighthouse::Generators::TypeGenerator < Lighthouse::Generators::ClassGenerator
  desc 'Generate the class of an SDL object type (a Types::BaseObject) in app/graphql/types.'

  private

  def kind = :types

  # graphql-ruby's naming: Post -> PostType.
  def class_basename
    name = super
    name.end_with?('Type') ? name : "#{name}Type"
  end

  def type_name
    class_basename.delete_suffix('Type')
  end

  def body
    <<~RUBY
      # Resolves fields of the #{type_name} type: a field with no resolving directive
      # calls the method of its snake_case name, when this class defines it. `object`
      # is the #{type_name} being resolved, `context` the query's context, and the
      # field's arguments arrive as snake_case keywords. The SDL declares the fields.
      class #{class_basename} < #{superclass_name}
        include Lighthouse::GraphQL::Type
      end
    RUBY
  end

  def usage
    "Fields of #{type_name} without a resolving directive now resolve with #{full_class_name}'s methods of the same (snake_case) name."
  end
end
