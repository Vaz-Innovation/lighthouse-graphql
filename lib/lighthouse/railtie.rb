# frozen_string_literal: true

# Hooks Lighthouse into a Rails host: exposes the `lighthouse:*` rake tasks,
# with `config.watch_sdl` reloads the app when a .graphql file changes, and
# with `config.ide_helper` (on in development when the app has a
# graphql.config.yml) rewrites the IDE helper files on boot and every reload,
# and with `config.schema_output` the client schema's file, in development.
# Generators (`rails g lighthouse:install`) are found through lib/generators.
class Lighthouse::Railtie < Rails::Railtie
  rake_tasks do
    load File.expand_path('tasks/lighthouse.rake', __dir__)
  end

  # After config/initializers (where Lighthouse.configure sets watch_sdl) and
  # before Rails builds its file watcher from config.watchable_dirs.
  initializer 'lighthouse.watch_sdl', after: :load_config_initializers, before: :set_clear_dependencies_hook do |app|
    Lighthouse::Railtie.watch_sdl(app.config)
  end

  initializer 'lighthouse.ide_helper', after: :load_config_initializers do |app|
    app.reloader.to_prepare { Lighthouse::IdeHelper.refresh(output_dir: app.root) }
  end

  # config.schema_output: the client schema's file, kept up to date in development.
  initializer 'lighthouse.schema_output', after: :load_config_initializers do |app|
    app.reloader.to_prepare { Lighthouse::GraphQL::SchemaPrinter.refresh }
  end

  # Rails' reloader then treats a .graphql edit like a Ruby one: the app's
  # constants — the schema among them — are reloaded on the next request.
  # Every .graphql under the entrypoint's folder is watched, imported or not.
  def self.watch_sdl(config)
    folder = Lighthouse::Config.schema_directory
    return false unless Lighthouse::Config.watch_sdl && folder

    config.watchable_dirs[folder.to_s] = %w[graphql graphqls]
    true
  end
end
