# frozen_string_literal: true

require 'securerandom'

# Where @upload puts a file, by default: an ActiveStorage blob, on the service
# `disk` names (the default service without it), its key under `path`. The
# argument then holds the blob's signed id, which a has_one_attached /
# has_many_attached attribute attaches, and which ActiveStorage::Blob.find_signed
# finds. Config.upload_store takes another `call(file, disk:, path:, public:)`.
module Lighthouse::GraphQL::UploadStore
  module_function

  def call(file, disk: nil, path: nil, public: false) # rubocop:disable Lint/UnusedMethodArgument -- public is the service's setting
    unless defined?(::ActiveStorage::Blob)
      raise Lighthouse::DefinitionError,
            '@upload stores files with ActiveStorage: install it (bin/rails active_storage:install), or set Config.upload_store.'
    end

    attributes = { io: file, filename: filename(file), content_type: file.try(:content_type), key: key(path) }
    attributes[:service_name] = disk if disk
    ::ActiveStorage::Blob.create_and_upload!(**attributes.compact).signed_id
  end

  def filename(file)
    file.respond_to?(:original_filename) ? file.original_filename : File.basename(file.path)
  end

  def key(path)
    prefix = path.to_s.delete_prefix('/').delete_suffix('/')
    prefix.empty? ? nil : "#{prefix}/#{SecureRandom.base36(28)}"
  end
end
