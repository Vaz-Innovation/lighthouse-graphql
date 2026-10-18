# frozen_string_literal: true

# Where @upload puts a file, as PHP Lighthouse's @upload puts it on one of the
# app's Laravel disks: an ActiveStorage blob on one of the app's services
# (config/storage.yml). `disk` names the service (config.active_storage.service
# without it), `path` prefixes the blob's key. ActiveStorage sets visibility per
# service (`public: true` in storage.yml), not per file, so `public` must agree
# with the service's: the schema never says a file is private that anyone can
# read, or public that no one can. The argument then holds the blob's signed id,
# which a has_one_attached / has_many_attached attribute attaches (where Laravel
# hands the stored path, for a model to keep). To store files elsewhere, declare
# an ActiveStorage service for it, as a Laravel app declares a disk.
module Lighthouse::GraphQL::UploadStore
  module_function

  def call(file, argument:, disk: nil, path: nil, public: nil)
    unless defined?(::ActiveStorage::Blob)
      raise Lighthouse::DefinitionError, '@upload stores files with ActiveStorage: install it (bin/rails active_storage:install).'
    end
    unless Lighthouse::GraphQL::Upload.file?(file)
      raise Lighthouse::DefinitionError, "Expected argument `#{argument}` to be an uploaded file (Upload)."
    end

    service = service(argument, disk, public == true)
    file.rewind if file.respond_to?(:rewind) # a @validator, or another argument the multipart map sent it to, may have read it
    ::ActiveStorage::Blob.create_and_upload!(
      io: file, filename: filename(file), content_type: file.try(:content_type), key: key(path), service_name: service.name
    ).signed_id
  end

  # The service `disk` names, or the default one, checked to be as public as asked.
  def service(argument, disk, public)
    service = disk ? ::ActiveStorage::Blob.services.fetch(disk) : ::ActiveStorage::Blob.service
    return service if (service.public? == true) == public

    raise Lighthouse::DefinitionError, visibility_mismatch(argument, service.name, public)
  rescue KeyError => e
    raise Lighthouse::DefinitionError, "@upload on `#{argument}`: #{e.message}"
  end

  def visibility_mismatch(argument, service_name, public)
    fix = public ? 'name a public one (public: true in config/storage.yml) with disk:' : 'pass public: true, or name a private one with disk:'
    "@upload#{'(public: true)' if public} on `#{argument}` stores on the ActiveStorage service `#{service_name}`, " \
      "which is #{'not ' if public}public: #{fix}."
  end

  def filename(file)
    file.respond_to?(:original_filename) ? file.original_filename : File.basename(file.path)
  end

  # `path`'s directory, then a fresh token, as Laravel's `storeAs(path, hashName)`;
  # under the root ("/", the default), ActiveStorage's own key.
  def key(path)
    prefix = path.to_s.delete_prefix('/').delete_suffix('/')
    prefix.empty? ? nil : "#{prefix}/#{::ActiveStorage::Blob.generate_unique_secure_token}"
  end
end
