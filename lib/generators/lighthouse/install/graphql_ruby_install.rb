# frozen_string_literal: true

# What graphql-ruby's `graphql:install` wrote in an app, as lighthouse:install
# reads it: where its schema class is (under app/, beside its types: --directory,
# --schema), which of its classes exist (--relay, --skip-mutation-root-type), and
# the parts of its templates Lighthouse takes out.
module Lighthouse::Generators::GraphqlRubyInstall
  # graphql-ruby's code-first root types and Node interface, by base_types key (RootTypes).
  ROOT_TYPES = { query_type: 'QueryType', mutation_type: 'MutationType', subscription_type: 'SubscriptionType', node: 'NodeType' }.freeze

  # graphql-ruby's base types, by base_types key.
  TYPE_BASES = {
    object: 'BaseObject', interface: 'BaseInterface', union: 'BaseUnion', scalar: 'BaseScalar',
    enum: 'BaseEnum', input_object: 'BaseInputObject'
  }.freeze

  # Where Lighthouse::GraphQL::Type goes in graphql-ruby's base types: after the
  # class line, or the interface's own include.
  TYPE_CONCERN_ANCHORS = {
    'base_object' => /^([ \t]*)class BaseObject < GraphQL::Schema::Object\n/,
    'base_union' => /^([ \t]*)class BaseUnion < GraphQL::Schema::Union\n/,
    'base_scalar' => /^([ \t]*)class BaseScalar < GraphQL::Schema::Scalar\n/,
    'base_interface' => /^([ \t]*)include GraphQL::Schema::Interface\n/
  }.freeze

  # The example field graphql-ruby's install puts in each root type.
  TEST_FIELD = /\n+[ \t]*# TODO: remove me\n[ \t]*field :test_field,.*?\n[ \t]*def test_field\n.*?\n[ \t]*end\n/m

  # The `resolve_type` stub graphql-ruby's install puts in the schema class.
  RESOLVE_TYPE_STUB = /
    \n+[ \t]*\#\ Union\ and\ Interface\ Resolution\n
    [ \t]*def\ self\.resolve_type\(.*?\)\n
    (?:[ \t]*\#.*\n)*
    [ \t]*raise\(GraphQL::RequiredImplementationMissingError\)\n
    [ \t]*end\n
  /x

  private

  # The file of graphql-ruby's schema class under app/ (--schema picks one by name), or nil.
  def schema_path
    @schema_path ||= Dir[File.join(destination_root, 'app', '**', '*.rb')].filter_map do |file|
      name = schema_class_name(File.read(file))
      file.delete_prefix("#{destination_root}/") if name && (options[:schema].nil? || name.demodulize == options[:schema].camelize)
    end.first
  end

  def schema_class_name(source)
    source[/^[ \t]*class (\S+) < (?:GraphQL::Schema|Lighthouse::GraphQL::RbLightHouse\.get_schema)\b/, 1] ||
      source[/^[ \t]*(\S+) = Lighthouse::GraphQL::RbLightHouse\.get_schema\b/, 1]
  end

  def schema_name
    schema_class_name(read(schema_path)).demodulize
  end

  def lighthouse?(source)
    source.include?('Lighthouse::GraphQL::RbLightHouse.get_schema')
  end

  # graphql-ruby's install: its defaults, an API app's smaller stack, the name --schema gives.
  def graphql_install_options
    { schema: options[:schema], api: api_only? || nil }.compact
  end

  def api_only?
    exist?('config/application.rb') && read('config/application.rb').match?(/^\s*config\.api_only\s*=\s*true/)
  end

  # graphql-ruby writes its types beside the schema class (--directory).
  def directory
    File.dirname(schema_path)
  end

  def types_path(file)
    File.join(directory, 'types', file)
  end

  # Lighthouse's base_types: every class graphql-ruby's install wrote, found
  # where it writes it, as [key, constant] pairs.
  def base_types
    @base_types ||= type_classes(ROOT_TYPES) + resolver_classes + type_classes(TYPE_BASES)
  end

  def type_classes(names)
    names.filter_map { |key, name| [key, "Types::#{name}"] if exist?(types_path("#{name.underscore}.rb")) }
  end

  def resolver_classes
    classes = { resolver: %w[resolvers BaseResolver], mutation: %w[mutations BaseMutation] }
    classes[:subscription] = %w[subscriptions BaseSubscription] if subscription_base?
    classes.filter_map do |key, (folder, name)|
      [key, "#{folder.camelize}::#{name}"] if exist?(File.join(directory, folder, "#{name.underscore}.rb"))
    end
  end

  def subscription_base?
    options[:subscriptions] || exist?(File.join(directory, 'subscriptions', 'base_subscription.rb'))
  end

  def graphql_ruby_controller?(source)
    source.include?('def prepare_variables(variables_param)') && source.include?('def handle_error_in_development(e)') &&
      source.include?("#{schema_name}.execute(query, variables: variables, context: context, operation_name: operation_name)")
  end

  def read(path)
    File.read(File.join(destination_root, path))
  end

  def exist?(path)
    File.exist?(File.join(destination_root, path))
  end
end
