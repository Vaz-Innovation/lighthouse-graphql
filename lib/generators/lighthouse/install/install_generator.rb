# frozen_string_literal: true

require 'rails/generators'
require 'lighthouse-graphql'

# `rails generate lighthouse:install` — sets a Rails app up for Lighthouse:
# the initializer, a starter SDL file, the schema class, a controller and
# its route, plus the graphql-config file IDEs read. Rerunning it skips the
# route, SDL and .gitignore entries that are already in place.
#
# It coexists with graphql-ruby's `graphql:install`, which writes the same
# controller path and route: an existing schema class or controller is kept
# (pass --force to replace it) instead of overwritten, so an app already
# serving a graphql-ruby schema keeps doing so until it is pointed at ours.
class Lighthouse::Generators::InstallGenerator < Rails::Generators::Base
  CONTROLLER = 'app/controllers/graphql_controller.rb'

  source_root File.expand_path('templates', __dir__)

  desc 'Install Lighthouse: initializer, starter schema, schema class, controller, route and IDE config.'

  class_option :schema, type: :string, default: 'AppSchema',
                        desc: 'Name of the schema constant to generate'
  class_option :sdl_folder, type: :string, default: 'graphql',
                            desc: 'Folder, relative to the app root, holding the *.graphql files'
  class_option :skip_controller, type: :boolean, default: false,
                                 desc: 'Skip the GraphqlController and its route'
  class_option :skip_ide, type: :boolean, default: false,
                          desc: 'Skip graphql.config.yml and the .gitignore entries for the IDE helper files'

  def create_initializer
    template 'initializer.rb.tt', 'config/initializers/lighthouse.rb'
  end

  def create_starter_schema
    if Dir[File.join(destination_root, sdl_folder, '**', '*.graphql')].any?
      say_status :skip, "#{sdl_folder}/ already has .graphql files", :yellow
      return
    end

    template 'schema.graphql.tt', File.join(sdl_folder, 'schema.graphql')
  end

  def create_schema_class
    path = File.join('app/graphql', "#{schema_name.underscore}.rb")
    return if keep_existing?(path)

    template 'schema.rb.tt', path
  end

  def create_controller
    return if options[:skip_controller]
    return if (@kept_controller = keep_existing?(CONTROLLER))

    template 'graphql_controller.rb.tt', CONTROLLER
  end

  def add_route
    return if options[:skip_controller]

    routes = File.join(destination_root, 'config/routes.rb')
    return unless File.exist?(routes)
    return if File.read(routes).include?('graphql#execute')

    # Byte-identical to graphql-ruby's install route, so whichever generator
    # runs second finds it in place and does not add it again.
    route 'post "/graphql", to: "graphql#execute"'
  end

  def create_ide_config
    return if options[:skip_ide]

    template 'graphql.config.yml.tt', 'graphql.config.yml'

    gitignore = File.join(destination_root, '.gitignore')
    return unless File.exist?(gitignore)

    entries = ide_helper_files.map { |file| "/#{file}" } - File.read(gitignore).lines.map(&:strip)
    return if entries.empty?

    append_to_file '.gitignore', "\n# Lighthouse IDE helper output (bin/rails lighthouse:ide_helper)\n#{entries.join("\n")}\n"
  end

  def show_next_steps
    serve =
      if @kept_controller
        "Serve it: #{CONTROLLER} was kept — have it call #{schema_name}.execute(...) to serve Lighthouse's schema."
      else
        'Query it:  POST /graphql  {"query": "{ users { data { id name } paginatorInfo { total } } }"}'
      end

    say <<~MSG

      Lighthouse is installed. Next steps:
        1. Describe your API in #{sdl_folder}/*.graphql (the starter schema assumes a User model).
        2. Generate the IDE helper files:  bin/rails lighthouse:ide_helper
        3. #{serve}
    MSG
  end

  private

  # Files another generator may own (graphql-ruby's install writes the same
  # controller) are left alone unless --force is given.
  def keep_existing?(path)
    return false if options[:force] || !File.exist?(File.join(destination_root, path))

    say_status :skip, "#{path} already exists (pass --force to replace it)", :yellow
    true
  end

  def schema_name
    options[:schema].camelize
  end

  def sdl_folder
    options[:sdl_folder].delete_suffix('/')
  end

  def default_sdl_folder?
    sdl_folder == 'graphql'
  end

  def ide_helper_files
    [Lighthouse::IdeHelper::DIRECTIVES_FILE, Lighthouse::IdeHelper::PROGRAMMATIC_TYPES_FILE]
  end
end
