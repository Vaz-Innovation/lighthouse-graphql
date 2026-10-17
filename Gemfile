# frozen_string_literal: true

source 'https://rubygems.org'

# Specify your gem's dependencies in lighthouse-graphql.gemspec
gemspec

gem 'rake', '~> 13.0'

group :development do
  gem 'ruby-lsp-rails', require: false
end

# dry-schema 1.14 forwards anonymous blocks in a way Ruby 3.1's parser rejects,
# although it declares 3.1 support; keep 3.1 on the release before it.
gem 'dry-schema', '< 1.14' if RUBY_VERSION < '3.2'
