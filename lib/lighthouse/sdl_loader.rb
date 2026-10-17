# frozen_string_literal: true

module Lighthouse::GraphQL::SDLLoader
  module_function

  def load_from_folder(folder)
    files = Dir[File.join(folder, '**', '*.graphql')]
    if files.empty?
      # fallback to the monolithic schema.graphql in apps/chatwoot
      # schema.graphql is located at apps/chatwoot/schema.graphql
      default = File.expand_path('../../..//schema.graphql', __dir__)
      return File.read(default) if File.exist?(default)

      return ''
    end

    files.map! { |f| File.read(f) }
    files.join("\n\n")
  end

  def load_from_file(path)
    File.read(path)
  end
end
