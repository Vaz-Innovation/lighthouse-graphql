# frozen_string_literal: true

# Canonical entrypoint for the `lighthouse-graphql` gem.
#
#   require 'lighthouse-graphql'
#
# Lighthouse brings PHP Lighthouse's SDL-first, directive-driven approach to
# building GraphQL APIs to Ruby on Rails. See docs/ for the full guide.
require_relative 'lighthouse/graphql/version'
require_relative 'lighthouse/rb_lighthouse'
