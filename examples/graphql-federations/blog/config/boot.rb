# The subgraphs share the bundle of examples/graphql-federations.
ENV['BUNDLE_GEMFILE'] ||= File.expand_path('../../Gemfile', __dir__)

require 'bundler/setup'
