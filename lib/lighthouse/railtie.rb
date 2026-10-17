# frozen_string_literal: true

module Lighthouse
  # Hooks Lighthouse into a Rails host: exposes the `lighthouse:*` rake tasks,
  # and — with `config.watch_sdl` — reloads the app when a .graphql file changes.
  # Generators (`rails g lighthouse:install`) are found through lib/generators.
  class Railtie < ::Rails::Railtie
    rake_tasks do
      load File.expand_path('tasks/lighthouse.rake', __dir__)
    end

    # After config/initializers (where Lighthouse.configure sets watch_sdl) and
    # before Rails builds its file watcher from config.watchable_dirs.
    initializer 'lighthouse.watch_sdl', after: :load_config_initializers, before: :set_clear_dependencies_hook do |app|
      Railtie.watch_sdl(app.config)
    end

    # Rails' reloader then treats a .graphql edit like a Ruby one: the app's
    # constants — the schema among them — are reloaded on the next request.
    def self.watch_sdl(config)
      folder = Lighthouse::Config.sdl_folder
      return false unless Lighthouse::Config.watch_sdl && folder

      config.watchable_dirs[folder.to_s] = %w[graphql graphqls]
      true
    end
  end
end
