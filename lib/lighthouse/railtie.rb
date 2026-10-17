# frozen_string_literal: true

module Lighthouse
  # Hooks Lighthouse into a Rails host: exposes the `lighthouse:*` rake tasks.
  # Generators (`rails g lighthouse:install`) are found through lib/generators.
  class Railtie < ::Rails::Railtie
    rake_tasks do
      load File.expand_path('tasks/lighthouse.rake', __dir__)
    end
  end
end
