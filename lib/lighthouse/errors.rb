# frozen_string_literal: true

module Lighthouse
  # The schema refers to something that does not exist or breaks a contract —
  # e.g. a Mutations:: class that is not a GraphQL::Schema::Mutation, or a
  # missing @validator class. A server bug, so not a client-facing error.
  class DefinitionError < StandardError; end

  # Raised by the @can* family when the policy denies the ability.
  class AuthorizationError < ::GraphQL::ExecutionError
    def initialize(message = 'This action is unauthorized.', **options)
      super
    end
  end

  # Invalid arguments — from a @validator contract or a model's validations.
  # Mirrors PHP Lighthouse's response: the messages are keyed by argument path
  # under `extensions.validation`, e.g. { "input.title" => ["Title can't be blank"] }.
  class ValidationError < ::GraphQL::ExecutionError
    attr_reader :messages

    def initialize(field_name, messages)
      @messages = messages
      super("Validation failed for the field [#{field_name}].", extensions: { 'validation' => messages })
    end
  end
end
