# frozen_string_literal: true

require 'rails/generators'
require 'generators/graphql/install_generator'
require 'lighthouse-graphql'
require_relative '../base_classes'
require_relative 'graphql_ruby_install'

# `rails generate lighthouse:install` — puts Lighthouse on top of graphql-ruby's
# own install (`rails g graphql:install`, with whichever of its options the app
# chose: --relay, --batch, --skip-mutation-root-type, --schema, --directory,
# ...). When the app has none, it runs graphql:install first, with its
# defaults. It then adapts what graphql-ruby wrote, instead of writing its own:
#
# - the schema class (`class AppSchema < GraphQL::Schema`) becomes Lighthouse's,
#   built from the SDL on everything graphql-ruby wrote: its base types, base
#   resolver and base mutation, and its code-first Types::QueryType /
#   MutationType, which the SDL's root types extend, so their `field`s (Relay's
#   `node` / `nodes`, what `graphql:mutation` adds) stay. Its Relay
#   Types::NodeType is the SDL's Node. Everything else in the class is
#   graphql-ruby's and stays, but the `resolve_type` stub (Lighthouse resolves
#   types) and the root types it is built on;
# - the example `test_field` goes from the root types;
# - graphql-ruby's base object, interface, union and scalar include
#   Lighthouse::GraphQL::Type, so every type class (Types::QueryType,
#   Types::NodeType, what `graphql:object` writes) is Lighthouse's;
# - with --batch, the schema uses GraphQL::Dataloader too, which Lighthouse's
#   directives batch through;
# - graphql-ruby's controller, as its install wrote it, becomes one with
#   Lighthouse::GraphQL::Controller.
#
# It adds the initializer, a starter SDL file and the graphql-config file IDEs
# read, and with --subscriptions, Subscriptions::BaseSubscription. Rerunning it
# skips what is in place.
class Lighthouse::Generators::InstallGenerator < Rails::Generators::Base
  include Lighthouse::Generators::BaseClasses
  include Lighthouse::Generators::GraphqlRubyInstall

  CONTROLLER = 'app/controllers/graphql_controller.rb'

  source_root File.expand_path('templates', __dir__)

  desc "Install Lighthouse on graphql-ruby's install: schema class, base classes, controller, initializer, starter SDL and IDE config."

  class_option :schema, type: :string,
                        desc: "The schema class to adopt; for graphql:install, when it runs, its name (default: graphql-ruby's)"
  class_option :schema_path, type: :string, default: 'graphql/schema.graphql',
                             desc: "The schema's entrypoint, relative to the app root; it #imports the other .graphql files"
  class_option :subscriptions, type: :boolean, default: false,
                               desc: 'Add Subscriptions::BaseSubscription, the base of the classes Subscription fields resolve to'
  class_option :skip_controller, type: :boolean, default: false,
                                 desc: "Leave graphql-ruby's GraphqlController as it is"
  class_option :skip_ide, type: :boolean, default: false,
                          desc: 'Skip graphql.config.yml and the .gitignore entries for the IDE helper files'

  # graphql-ruby's install: the app's, or one now, with graphql-ruby's defaults.
  def install_graphql_ruby
    return if schema_path

    say_status :invoke, 'graphql:install (no graphql-ruby schema found)', :blue
    invoke 'graphql:install', [], graphql_install_options
    @schema_path = nil
    return if schema_path

    raise Thor::Error, "No graphql-ruby schema class (class #{options[:schema] || 'AppSchema'} < GraphQL::Schema) under app/: " \
                       'run `bin/rails g graphql:install` first.'
  end

  def create_initializer
    template 'initializer.rb.tt', 'config/initializers/lighthouse.rb'
  end

  def create_starter_schema
    if File.exist?(File.join(destination_root, sdl_schema_path))
      say_status :skip, "#{sdl_schema_path} exists", :yellow
      return
    end

    template 'schema.graphql.tt', sdl_schema_path
  end

  # Subscriptions::BaseSubscription, which graphql-ruby has none of (see BaseClasses).
  def create_base_subscription
    write_base_class(:subscriptions, Lighthouse::Config.namespaces[:subscriptions].first) if options[:subscriptions]
  end

  # graphql-ruby's schema class, built by Lighthouse from the SDL on its classes.
  def adopt_schema_class
    source = read(schema_path)
    if lighthouse?(source)
      say_status :skip, "#{schema_path} is Lighthouse's already", :yellow
      return
    end

    declaration = /^([ \t]*)class (\S+) < GraphQL::Schema[ \t]*\n/
    indent, name = source.match(declaration).captures
    gsub_file schema_path, declaration, "#{indent}#{schema_comment(indent)}#{indent}class #{name} < #{schema_superclass(indent)}\n"
    gsub_file schema_path, /^[ \t]*(query|mutation|subscription)\(Types::(Query|Mutation|Subscription)Type\)\n/, ''
    gsub_file schema_path, /^(#{indent}\)\n)\n+/, '\\1'
    gsub_file schema_path, RESOLVE_TYPE_STUB, "\n"
    add_dataloader if source.include?('use GraphQL::Batch') && source.exclude?('use GraphQL::Dataloader')
  end

  # The example field goes; the root types' own fields stay.
  def adapt_root_types
    %w[query_type mutation_type subscription_type].each do |name|
      path = types_path("#{name}.rb")
      gsub_file path, TEST_FIELD, "\n" if exist?(path) && read(path).match?(TEST_FIELD)
    end
  end

  # Every type class is Lighthouse's: graphql-ruby's base object, interface,
  # union and scalar include Lighthouse::GraphQL::Type, so the classes that
  # inherit from them (Types::QueryType, Types::NodeType, what `graphql:object`
  # writes) lend their methods to the SDL's types of their name.
  def adapt_type_bases
    TYPE_CONCERN_ANCHORS.each do |name, anchor|
      path = types_path("#{name}.rb")
      next if !exist?(path) || read(path).include?('Lighthouse::GraphQL::Type')

      indent = read(path)[anchor, 1]
      next unless indent

      indent += '  ' unless name == 'base_interface'
      inject_into_file path, "#{indent}# Lighthouse's: the class of the SDL type of its name lends that type its methods.\n" \
                             "#{indent}include Lighthouse::GraphQL::Type\n", after: anchor
    end
  end

  # graphql-ruby's controller, as its install wrote it, serves the schema with
  # Lighthouse's concern. One the app has changed is left alone.
  def adapt_controller
    return if options[:skip_controller] || !exist?(CONTROLLER)
    return if read(CONTROLLER).include?('Lighthouse::GraphQL::Controller')
    return @kept_controller = true unless graphql_ruby_controller?(read(CONTROLLER))

    template 'graphql_controller.rb.tt', CONTROLLER, force: true
  end

  def add_route
    return if options[:skip_controller]

    routes = File.join(destination_root, 'config/routes.rb')
    return unless File.exist?(routes)
    return if File.read(routes).include?('graphql#execute')

    # Byte-identical to graphql-ruby's install route.
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
        "Serve it: #{CONTROLLER} was changed from graphql-ruby's, so it was kept — " \
          "include Lighthouse::GraphQL::Controller in it, or keep calling #{schema_name}.execute(...)."
      else
        'Query it:  POST /graphql  {"query": "{ users { data { id name } paginatorInfo { total } } }"}'
      end

    say <<~MSG

      Lighthouse is installed on graphql-ruby's install (#{schema_path}). Next steps:
        1. Describe your API in #{sdl_schema_path} (the starter assumes a User model); #import more files, which `extend type Query`.
        2. Resolve a field in Ruby when a directive is not enough, as in graphql-ruby: a method of
           Types::QueryType (Query.latestPosts -> #latest_posts), a `field` of its own there,
           `bin/rails g graphql:mutation`, or a Resolvers::BaseResolver subclass named after the field.
        3. Give a type Ruby methods, a union or interface its resolve_type, a scalar its coercion:
           bin/rails g graphql:object Post (or graphql:union, graphql:interface, graphql:scalar);
           the class is Lighthouse's through its base (Lighthouse::GraphQL::Type)
        4. The IDE helper files are rewritten in development; or:  bin/rails lighthouse:ide_helper
        5. #{serve}
    MSG
  end

  private

  def schema_superclass(indent)
    lines = base_types.map { |key, name| "#{indent}      #{key}: #{name}" }
    "Lighthouse::GraphQL::RbLightHouse.get_schema(\n#{indent}  options: {\n#{indent}    base_types: {\n" \
      "#{lines.join(",\n")}\n#{indent}    }\n#{indent}  }\n#{indent})"
  end

  def schema_comment(indent)
    <<~RUBY.gsub(/^/, indent).delete_prefix(indent)
      # Lighthouse builds the schema from the SDL in #{sdl_schema_path}, on the classes graphql-ruby's
      # install wrote (base_types): the SDL's root types extend the code-first ones, whose
      # `field`s stay the schema's, and every type, resolver and mutation class inherits from
      # its kind's base. The rest of the class is graphql-ruby's.
    RUBY
  end

  def add_dataloader
    anchor = /^([ \t]*)use GraphQL::Batch\n/
    indent = read(schema_path)[anchor, 1]
    inject_into_file schema_path, "#{indent}# Lighthouse's directives batch through GraphQL::Dataloader, beside GraphQL::Batch.\n" \
                                  "#{indent}use GraphQL::Dataloader\n", after: anchor
  end

  # The SDL's entrypoint (Config.schema_path); `schema_path` is graphql-ruby's schema class.
  def sdl_schema_path
    options[:schema_path].delete_prefix('/')
  end

  def sdl_folder
    File.dirname(sdl_schema_path)
  end

  def default_sdl_schema_path?
    sdl_schema_path == 'graphql/schema.graphql'
  end

  def ide_helper_files
    [Lighthouse::IdeHelper::DIRECTIVES_FILE, Lighthouse::IdeHelper::PROGRAMMATIC_TYPES_FILE]
  end
end
