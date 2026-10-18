# frozen_string_literal: true

# The `Upload` scalar: a file a client sends with a multipart request (the
# GraphQL multipart request specification, MultipartRequest). `scalar Upload`
# in the SDL reads its values through it unless the SDL or a type class names
# another class. The resolver gets the uploaded file (an
# ActionDispatch::Http::UploadedFile in Rails): attach it to a model
# (`avatar: Upload` with @create on a model with has_one_attached :avatar), or
# store it with @upload.
class Lighthouse::GraphQL::Upload < GraphQL::Schema::Scalar
  graphql_name 'Upload'

  def self.coerce_input(value, _context)
    return value if file?(value)

    raise ::GraphQL::CoercionError,
          'Could not get uploaded file, be sure to conform to GraphQL multipart request specification: ' \
          "https://github.com/jaydenseric/graphql-multipart-request-spec. Instead got: #{value.inspect}."
  end

  def self.coerce_result(_value, _context)
    raise ::GraphQL::Error, '"Upload" cannot be serialized, it can only be used as an argument.'
  end

  def self.file?(value)
    value.respond_to?(:read) && (value.respond_to?(:original_filename) || value.respond_to?(:path))
  end
end
