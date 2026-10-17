# frozen_string_literal: true

source 'https://rubygems.org'

# Specify your gem's dependencies in lighthouse-graphql.gemspec
gemspec

gem 'rake', '~> 13.0'

# dry-schema 1.14 forwards anonymous blocks in a way Ruby 3.1's parser rejects,
# although it declares 3.1 support; keep 3.1 on the release before it.
gem 'dry-schema', '< 1.14' if RUBY_VERSION < '3.2'

group :lint do
  gem 'rubocop', '~> 1.91', require: false
  gem 'rubocop-factory_bot', '~> 2.28', require: false
  gem 'rubocop-performance', '~> 1.27', require: false
  gem 'rubocop-rails', '~> 2.38', require: false
  gem 'rubocop-rspec', '~> 3.10', require: false
end
