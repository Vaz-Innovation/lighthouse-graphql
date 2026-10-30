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
#
# A blob is stored before the field resolves (after @guard, @can* and
# @validator), and the model's own validations run after. When the field
# fails, the blobs it stored are purged, so a refused mutation leaves no blob
# and no file behind: see purge_on_failure.
module Lighthouse::GraphQL::UploadStore
  # The fiber-local list of the blobs stored for the field resolving: graphql-ruby's
  # dataloader runs each field in a fiber of its own.
  STORED = :lighthouse_uploads_stored

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
    blob = ::ActiveStorage::Blob.create_and_upload!(
      io: file, filename: filename(file), content_type: file.try(:content_type), key: key(path), service_name: service.name
    )
    Thread.current[STORED]&.push(blob)
    blob.signed_id
  end

  # Runs the block, a field's resolution, and purges the blobs @upload stored
  # meanwhile when it fails: it raises, returns a GraphQL::ExecutionError, or
  # adds an error to the query's `context`. Nested in another, a success
  # hands its blobs to the outer one.
  def purge_on_failure(context)
    outer = Thread.current[STORED]
    blobs = Thread.current[STORED] = []
    errors = error_count(context)
    result = yield
    failed?(result, context, errors) ? purge(blobs) : outer&.concat(blobs)
    result
  rescue StandardError
    purge(blobs || [])
    raise
  ensure
    Thread.current[STORED] = outer
  end

  # Not Array(result): a relation would be loaded.
  def failed?(result, context, errors_before)
    result.is_a?(::GraphQL::ExecutionError) || (result.is_a?(Array) && result.any?(::GraphQL::ExecutionError)) ||
      error_count(context) > errors_before
  end

  def error_count(context)
    context.respond_to?(:errors) ? context.errors.size : 0
  end

  # Now, not later: the blobs are attached to nothing, and the client is told
  # the mutation failed, so none outlives the response. One the service fails
  # to delete is left to ActiveStorage's job to retry.
  def purge(blobs)
    blobs.each do |blob|
      blob.purge
    rescue StandardError
      blob.purge_later
    end
    blobs.clear
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
