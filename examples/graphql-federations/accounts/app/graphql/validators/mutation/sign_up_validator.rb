# Runs before Mutation.signUp because the field carries @validator. Arguments
# arrive with snake_case keys. Rules that belong to the model (presence,
# uniqueness) stay in User; this contract holds the ones that do not.
class Validators::Mutation::SignUpValidator < Dry::Validation::Contract
  RESERVED_DOMAINS = %w[example.org].freeze

  params do
    required(:name).filled(:string)
    required(:email).filled(:string)
  end

  rule(:email) do
    key.failure('is not an email address') unless value.match?(URI::MailTo::EMAIL_REGEXP)
    key.failure('uses a reserved domain') if RESERVED_DOMAINS.include?(value.split('@').last)
  end
end
