# frozen_string_literal: true

require_relative 'base'

# @attachment — the URL of an ActiveStorage attachment of the parent: the read
# side of @upload, Lighthouse's (Laravel has no ActiveStorage).
#
#   type User {
#     avatarUrl: String @attachment                                # has_one_attached :avatar
#     avatarThumbUrl: String @attachment(name: "avatar", variant: "thumb")
#     photoUrls: [String!]! @attachment(url: PROXY)                # has_many_attached :photos
#   }
#
# Every parent's attachments and their blobs are loaded at once
# (`avatar_attachment: :blob`, what `User.with_attached_avatar` loads), through
# the Dataloader when the schema uses it. `name` defaults to the field's name
# without its Url / Urls suffix: avatarUrl reads `avatar`, photoUrls `photos`.
#
# `url` says how the URL serves the file: REDIRECT (Rails' redirect to the
# service, the default), PROXY (streamed through the app) or DIRECT (the
# service's own URL, signed for `expiresIn` on a private one). A REDIRECT or
# PROXY URL is absolute when the request's host is known (the controller in the
# context, else the routes' default_url_options), else a path. A variant is
# processed when its URL is first followed, except DIRECT, which processes it
# while resolving.
class Lighthouse::GraphQL::DirectiveResolvers::AttachmentDirectiveResolver < Lighthouse::GraphQL::DirectiveResolvers::BaseDirectiveResolver
  TYPE_DEFINITIONS = {
    'AttachmentUrl' => <<~GRAPHQL.chomp
      "How an @attachment URL serves the file."
      enum AttachmentUrl {
        "Rails' redirect to the storage service (rails_storage_redirect_url)."
        REDIRECT
        "Streamed through the app (rails_storage_proxy_url)."
        PROXY
        "The storage service's own URL, signed for expiresIn on a private service."
        DIRECT
      }
    GRAPHQL
  }.freeze

  def self.directive_name = 'attachment'

  def self.type_definitions = TYPE_DEFINITIONS

  def self.definition
    <<~GRAPHQL.chomp
      """
      The URL of an ActiveStorage attachment of the parent, or the URLs of a has_many_attached.
      Every parent's attachments and blobs are loaded at once.
      """
      directive @attachment(
        "The attachment's name. Defaults to the field's name without its Url / Urls suffix."
        name: String
        "A named variant of the attachment (`has_one_attached :avatar { |a| a.variant :thumb, ... }`)."
        variant: String
        "How the URL serves the file."
        url: AttachmentUrl = REDIRECT
        "How many seconds a DIRECT URL is valid. Defaults to ActiveStorage.service_urls_expire_in."
        expiresIn: Int
      ) on FIELD_DEFINITION
    GRAPHQL
  end

  def define_resolver(target_type_class)
    me = self
    install(target_type_class, ->(obj, _args, ctx) { me.send(:resolve, obj, ctx) })
  end

  protected

  def resolve(record, ctx)
    return if record.nil?

    reflection = reflection(record)
    preload(record, reflection, ctx)
    attached = record.public_send(attachment_name)
    return attached.attachments.filter_map { |attachment| url(attachment, ctx) } if reflection.macro == :has_many_attached

    url(attached.attachment, ctx) if attached.attached?
  end

  def attachment_name
    @attachment_name ||= (directive_arg('name') || default_name).to_s
  end

  # avatarUrl -> avatar, photoUrls -> photos, avatar -> avatar.
  def default_name
    attribute = Lighthouse::Support::Naming.attribute(@field_def.name)
    attribute.end_with?('_urls') ? attribute.delete_suffix('_urls').pluralize : attribute.delete_suffix('_url')
  end

  def reflection(record)
    reflection = record.class.respond_to?(:reflect_on_attachment) && record.class.reflect_on_attachment(attachment_name)
    return reflection if reflection

    raise Lighthouse::DefinitionError,
          "@attachment on #{@type_def.graphql_name}.#{@field_def.name}: #{record.class.name} has no attachment `#{attachment_name}`."
  end

  def preload(record, reflection, ctx)
    dataloader = Lighthouse::Support::Batching.dataloader(ctx)
    return unless dataloader

    association = reflection.macro == :has_many_attached ? :"#{attachment_name}_attachments" : :"#{attachment_name}_attachment"
    dataloader.with(Lighthouse::GraphQL::DataloaderSources::PreloadLoader, [{ association => :blob }], []).load(record)
  end

  def url(attachment, ctx)
    variant = directive_arg('variant')
    return if variant && !attachment.variable?

    target = variant ? attachment.variant(variant.to_sym) : attachment
    options = url_options(ctx)
    case directive_arg('url')
    when 'DIRECT' then direct_url(target, options)
    when 'PROXY' then route(:rails_storage_proxy, target, options)
    else route(:rails_storage_redirect, target, options)
    end
  end

  def route(name, target, options)
    helpers = ::Rails.application.routes.url_helpers
    options[:host] ? helpers.public_send(:"#{name}_url", target, **options) : helpers.public_send(:"#{name}_path", target)
  end

  # The service signs the URL; the Disk service builds it from ActiveStorage::Current's host.
  def direct_url(target, options)
    target = target.processed if target.respond_to?(:processed)
    expires_in = directive_arg('expiresIn')&.seconds || ::ActiveStorage.service_urls_expire_in
    ::ActiveStorage::Current.set(url_options: options.slice(:host, :port, :protocol)) { target.url(expires_in: expires_in) }
  end

  # The request's, through the controller in the context, else the routes' defaults.
  def url_options(ctx)
    controller = ctx.respond_to?(:[]) ? ctx[:lighthouse_controller] : nil
    options = controller.respond_to?(:url_options) ? controller.url_options : ::Rails.application.routes.default_url_options
    options.to_h.symbolize_keys.slice(:host, :port, :protocol, :script_name)
  end
end
