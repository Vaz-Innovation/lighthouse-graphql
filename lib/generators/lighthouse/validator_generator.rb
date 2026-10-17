# frozen_string_literal: true

require_relative 'class_generator'

module Lighthouse
  module Generators
    # `rails generate lighthouse:validator CreatePostInput` — a
    # Dry::Validation::Contract for @validator. Name it after an input type
    # (CreatePostInputValidator) or a field (Mutation::CreatePostValidator).
    class ValidatorGenerator < ClassGenerator
      desc 'Generate a validator (Dry::Validation::Contract) for @validator in app/graphql/validators.'

      private

      def kind = :validators

      def class_basename
        base = super
        base.end_with?('Validator') ? base : "#{base}Validator"
      end

      def body
        <<~RUBY
          # Arguments arrive with snake_case keys. Remove `option :graphql_context`
          # if the rules don't need the GraphQL context.
          class #{class_basename} < Dry::Validation::Contract
            option :graphql_context, optional: true

            params do
            end
          end
        RUBY
      end

      def usage
        'Needs the dry-validation gem. Add @validator to the input type or field it is named after.'
      end
    end
  end
end
