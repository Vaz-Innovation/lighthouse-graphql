# frozen_string_literal: true

require_relative 'class_generator'

# `rails generate lighthouse:mutation PublishPost` — the class (a
# Mutations::BaseMutation, so a GraphQL::Schema::Mutation) that `Mutation.publishPost`
# resolves to by convention.
class Lighthouse::Generators::MutationGenerator < Lighthouse::Generators::ClassGenerator
  desc 'Generate the class of a Mutation field (a Mutations::BaseMutation) in app/graphql/mutations.'

  private

  def kind = :mutations

  def body
    <<~RUBY
      # Resolves Mutation.#{class_basename.camelize(:lower)}. Keyword arguments are the field's
      # arguments in snake_case; `object` and `context` are available. Raise
      # GraphQL::ExecutionError for failures the client should see.
      class #{class_basename} < #{superclass_name}
        def resolve(**args)
          raise NotImplementedError
        end
      end
    RUBY
  end

  def usage
    "Mutation.#{class_basename.camelize(:lower)} resolves to #{full_class_name} — add the field to your SDL without a resolving directive."
  end
end
