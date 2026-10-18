# frozen_string_literal: true

require 'rails/generators'
require 'lighthouse-graphql'

# The base class graphql-ruby's convention puts in each namespace, which the
# classes Lighthouse generates inherit from.
#
# graphql-ruby's `graphql:install` writes Resolvers::BaseResolver,
# Mutations::BaseMutation and every Types::Base*, and `lighthouse:install`
# builds on them: Lighthouse does not write copies of them. It writes only the
# base graphql-ruby has none of, Subscriptions::BaseSubscription, which
# includes Lighthouse's subscription concern.
#
# A base that already exists is never replaced, not even with --force: it holds
# the app's own code.
module Lighthouse::Generators::BaseClasses
  NAMES = { subscriptions: 'BaseSubscription' }.freeze

  # The bases Lighthouse writes itself, graphql-ruby having none.
  SOURCES = {
    subscriptions: <<~RUBY
      # What every class resolving a Subscription field shares. The concern is PHP
      # Lighthouse's model: every subscriber of a field gets every broadcast, and the
      # class's `filter?` decides who receives it. A subclass that defines
      # graphql-ruby's own `authorized?` or `update` keeps them, and `topic_by
      # :arguments` brings back graphql-ruby's exact-argument matching.
      class BaseSubscription < GraphQL::Schema::Subscription
        include Lighthouse::GraphQL::Subscription
      end
    RUBY
  }.freeze

  private

  # The base class name for `kind` (`BaseResolver`), or nil for a kind without one.
  def base_class_name(kind)
    NAMES[kind]
  end

  # Write the base class of `kind` into `namespace` when it is missing.
  def write_base_class(kind, namespace)
    return unless base_class_name(kind)

    path = base_class_path(kind, namespace)
    if File.exist?(File.join(destination_root, path))
      say_status :skip, "#{path} already exists", :yellow
    else
      create_file path, ruby_source(namespace.split('::'), SOURCES.fetch(kind))
    end
  end

  def base_class_path(kind, namespace)
    File.join('app/graphql', *namespace.split('::').map(&:underscore), "#{base_class_name(kind).underscore}.rb")
  end

  # Ruby source defining `body` inside the nested `modules`.
  def ruby_source(modules, body)
    lines = ['# frozen_string_literal: true', '']
    modules.each_with_index { |mod, depth| lines << "#{'  ' * depth}module #{mod}" }
    body.each_line { |line| lines << (line.strip.empty? ? '' : "#{'  ' * modules.size}#{line.chomp}") }
    modules.size.times.reverse_each { |depth| lines << "#{'  ' * depth}end" }
    "#{lines.join("\n")}\n"
  end
end
