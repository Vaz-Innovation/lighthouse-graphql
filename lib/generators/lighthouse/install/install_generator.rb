# frozen_string_literal: true

require 'rails/generators'
require 'generators/graphql/install_generator'
require 'lighthouse-graphql'
require_relative '../base_classes'

# `rails generate lighthouse:install` — sets a Rails app up for Lighthouse, on
# top of graphql-ruby's own install, which it runs first (`graphql:install
# --no-relay --skip-graphiql --skip-query-logs`, keeping the files the app has):
# graphql-ruby writes the base classes every graphql-ruby app has (Types::Base*,
# Resolvers::BaseResolver, Mutations::BaseMutation), its controller and route.
# Lighthouse then puts its own over what graphql-ruby wrote in this run:
#
# - the schema class, built from the SDL (graphql-ruby's is code-first);
# - the controller, with Lighthouse::GraphQL::Controller;
# - no Types::QueryType / MutationType: the SDL declares the root types;
# - Mutations::BaseMutation a GraphQL::Schema::Mutation, as the SDL declares a
#   mutation's arguments (graphql-ruby's is a RelayClassicMutation, one `input:`);
#
# and adds the initializer, a starter SDL file, Subscriptions::BaseSubscription
# and the graphql-config file IDEs read. Rerunning it skips what is in place. A
# schema class or controller the app had before is kept (pass --force to replace
# it), so an app already serving a graphql-ruby schema keeps doing so until it
# is pointed at ours.
class Lighthouse::Generators::InstallGenerator < Rails::Generators::Base
  include Lighthouse::Generators::BaseClasses

  CONTROLLER = 'app/controllers/graphql_controller.rb'
  ROOT_TYPES = %w[app/graphql/types/query_type.rb app/graphql/types/mutation_type.rb].freeze
  BASE_MUTATION = 'app/graphql/mutations/base_mutation.rb'

  source_root File.expand_path('templates', __dir__)

  desc 'Install Lighthouse: initializer, starter schema, schema class, base classes, controller, route and IDE config.'

  class_option :schema, type: :string, default: 'AppSchema',
                        desc: 'Name of the schema constant to generate'
  class_option :sdl_folder, type: :string, default: 'graphql',
                            desc: 'Folder, relative to the app root, holding the *.graphql files'
  class_option :skip_controller, type: :boolean, default: false,
                                 desc: 'Skip the GraphqlController and its route'
  class_option :skip_ide, type: :boolean, default: false,
                          desc: 'Skip graphql.config.yml and the .gitignore entries for the IDE helper files'

  # graphql-ruby's install, for the base classes. What it writes that Lighthouse
  # replaces is noted, so a file the app had before is never touched.
  def install_graphql_ruby
    @before = ([schema_path, CONTROLLER, BASE_MUTATION] + ROOT_TYPES).select { |path| exist?(path) }
    invoke 'graphql:install', [], schema: schema_name, relay: false, skip_graphiql: true, skip_query_logs: true, skip: true
  end

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
    return if keep_existing?(schema_path)

    template 'schema.rb.tt', schema_path, force: true
  end

  # The SDL declares the root types: graphql-ruby's code-first ones go. Not when
  # the app keeps a code-first schema of its own, which graphql-ruby's install
  # pointed at them.
  def remove_root_types
    return unless exist?(schema_path) && File.read(File.join(destination_root, schema_path)).include?('RbLightHouse.get_schema')

    ROOT_TYPES.each { |path| remove_file path unless before?(path) }
  end

  # The SDL declares a mutation's arguments, so its class is a plain
  # GraphQL::Schema::Mutation, not graphql-ruby's RelayClassicMutation.
  def adapt_base_mutation
    return if before?(BASE_MUTATION) || !exist?(BASE_MUTATION)

    gsub_file BASE_MUTATION, 'GraphQL::Schema::RelayClassicMutation', 'GraphQL::Schema::Mutation'
    gsub_file BASE_MUTATION, /^\s*input_object_class .*\n/, ''
  end

  # Subscriptions::BaseSubscription, which graphql-ruby has none of (see BaseClasses).
  def create_base_subscription
    write_base_class(:subscriptions, Lighthouse::Config.namespaces[:subscriptions].first)
  end

  def create_controller
    return remove_graphql_ruby_controller if options[:skip_controller]
    return if (@kept_controller = keep_existing?(CONTROLLER))

    template 'graphql_controller.rb.tt', CONTROLLER, force: true
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
        2. Resolve a field in Ruby when a directive is not enough:  bin/rails g lighthouse:query LatestPosts
           (it inherits from Resolvers::BaseResolver, which graphql-ruby's install wrote; lighthouse:mutation and
           lighthouse:subscription write the others)
        3. Give a type Ruby methods, a union or interface its resolve_type, a scalar its coercion:
           bin/rails g graphql:object Post (or graphql:union, graphql:interface, graphql:scalar),
           then include Lighthouse::GraphQL::Type in the class
        4. Generate the IDE helper files:  bin/rails lighthouse:ide_helper
        5. #{serve}
    MSG
  end

  private

  # A file the app had before this run is left alone unless --force is given;
  # one graphql-ruby's install wrote in this run is Lighthouse's to replace.
  def keep_existing?(path)
    return false if options[:force] || !before?(path)

    say_status :skip, "#{path} already exists (pass --force to replace it)", :yellow
    true
  end

  def before?(path)
    @before.include?(path)
  end

  def exist?(path)
    File.exist?(File.join(destination_root, path))
  end

  def schema_path
    File.join('app/graphql', "#{schema_name.underscore}.rb")
  end

  # --skip-controller: the app serves the schema itself, so graphql-ruby's
  # controller and route, if its install just wrote them, go.
  def remove_graphql_ruby_controller
    return if before?(CONTROLLER)

    remove_file CONTROLLER
    gsub_file 'config/routes.rb', %r{^\s*post "/graphql", to: "graphql#execute"\n}, '' if exist?('config/routes.rb')
  end

  def schema_name
    options[:schema].camelize
  end

  # `Resolvers::BaseResolver`, for the schema class template.
  def base_class_constant(kind)
    "#{Lighthouse::Config.namespaces[kind].first}::#{base_class_name(kind)}"
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
