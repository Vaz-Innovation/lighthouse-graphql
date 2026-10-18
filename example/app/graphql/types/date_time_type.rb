# The SDL's `scalar DateTime`, as graphql-ruby's `rails g graphql:scalar` writes a
# scalar. Including Lighthouse::GraphQL::Type hands it to Lighthouse: an argument
# arrives in Ruby as a Time, and a Time (Post#created_at) leaves as ISO 8601.
class Types::DateTimeType < Types::BaseScalar
  include Lighthouse::GraphQL::Type

  def self.coerce_input(value, _context)
    Time.iso8601(value.to_s)
  rescue ArgumentError
    raise GraphQL::CoercionError, "#{value.inspect} is not an ISO 8601 date and time"
  end

  def self.coerce_result(value, _context)
    value.utc.iso8601
  end
end
