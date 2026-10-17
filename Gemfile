# frozen_string_literal: true

source 'https://rubygems.org'

# Specify your gem's dependencies in lighthouse-graphql.gemspec
gemspec

gem 'rake', '~> 13.0'

group :development, :test do
  gem 'activerecord', '>= 6.0'
  gem 'apollo-federation', '~> 3.0'
  gem 'rspec', '~> 3.0'
  gem 'sqlite3', '>= 1.4'
  # Exercises the Rails generator and rake task; a Rails host provides it at runtime.
  gem 'railties', '>= 6.0'
  # Optional at runtime: @broadcast queues its trigger as a Lighthouse::GraphQL::BroadcastJob with it.
  gem 'activejob', '>= 6.0'
  # Optional integrations, exercised by the specs: Pundit backs the @can* family
  # by default, and @validator accepts Dry::Validation contracts.
  gem 'dry-validation', '~> 1.10'
  gem 'pundit', '>= 2.0'
  # The soft-delete gems @softDeletes, @trashed, @restore and @forceDelete detect; the specs exercise both.
  gem 'discard', '~> 1.3'
  gem 'paranoia', '>= 2.6'
  # Backs @feature by default; the specs use its in-memory adapter.
  gem 'flipper', '~> 1.3'
end

# dry-schema 1.14 forwards anonymous blocks in a way Ruby 3.1's parser rejects,
# although it declares 3.1 support; keep 3.1 on the release before it.
gem 'dry-schema', '< 1.14' if RUBY_VERSION < '3.2'

group :lint do
  # Validates sig/, and checks it against the suite at runtime (rake rbs).
  gem 'rbs', '>= 3.6', require: false
  gem 'rubocop', '~> 1.92', require: false
  gem 'rubocop-factory_bot', '~> 2.28', require: false
  gem 'rubocop-performance', '~> 1.27', require: false
  gem 'rubocop-rails', '~> 2.38', require: false
  gem 'rubocop-rspec', '~> 3.10', require: false
end
