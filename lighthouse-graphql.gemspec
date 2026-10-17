# frozen_string_literal: true

require_relative 'lib/lighthouse/graphql/version'

Gem::Specification.new do |spec|
  spec.name = 'lighthouse-graphql'
  spec.version = Lighthouse::GraphQL::VERSION
  spec.authors = ['Vaz Innovation']
  spec.email = ['engineering@vazinnovation.com']

  spec.summary = 'SDL-first, directive-driven GraphQL for Ruby on Rails — a port of PHP Lighthouse.'
  spec.description = <<~DESC
    Lighthouse lets you build a GraphQL API for your Rails app primarily through
    schema (SDL) and server-side directives — @all, @find, @paginate, @hasMany,
    @belongsTo, @whereConditions, @orderBy, @field, @auth and more — instead of
    hand-writing a resolver for every field. It is a Ruby adaptation of the PHP
    Lighthouse library (nuwave/lighthouse) built on top of graphql-ruby, with
    first-class Apollo Federation support so a Rails service can act as a subgraph.
  DESC

  spec.homepage = 'https://github.com/Vaz-Innovation/lighthouse-graphql'
  spec.license = 'MIT'
  spec.required_ruby_version = '>= 3.0'

  spec.metadata = {
    'source_code_uri' => spec.homepage,
    'changelog_uri' => "#{spec.homepage}/blob/main/CHANGELOG.md",
    'documentation_uri' => "#{spec.homepage}/tree/main/docs",
    'rubygems_mfa_required' => 'true'
  }

  # Generator templates (.tt) and rake tasks live under lib/ next to the code.
  spec.files = Dir[
    'lib/**/*',
    'docs/**/*.md',
    'README.md',
    'CHANGELOG.md',
    'LICENSE.txt'
  ]
  spec.require_paths = ['lib']

  # Runtime
  spec.add_dependency 'activesupport', '>= 6.0'
  spec.add_dependency 'graphql', '~> 2.5'

  # Pundit (@can*) and dry-validation (@validator) are optional too: Lighthouse
  # only touches them when a schema uses those directives with their defaults.
  #
  # Apollo Federation (`apollo-federation` gem) is an OPTIONAL runtime dependency:
  # the federation entity binding only activates when the host app's base types
  # include the ApolloFederation mixins. It is therefore not declared as a hard
  # dependency so non-federated apps can use Lighthouse without it.

  # Development
  spec.add_development_dependency 'rspec', '~> 3.0'
  spec.add_development_dependency 'activerecord', '>= 6.0'
  spec.add_development_dependency 'sqlite3', '>= 1.4'
  spec.add_development_dependency 'apollo-federation', '~> 3.0'
  # Exercises the Rails generator and rake task; a Rails host provides it at runtime.
  spec.add_development_dependency 'railties', '>= 6.0'
  # Optional integrations, exercised by the specs: Pundit backs the @can* family
  # by default, and @validator accepts Dry::Validation contracts.
  spec.add_development_dependency 'pundit', '>= 2.0'
  spec.add_development_dependency 'dry-validation', '~> 1.10'
end
