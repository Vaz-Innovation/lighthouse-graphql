# frozen_string_literal: true

require 'rails/generators'
require 'lighthouse-graphql'

# The base class graphql-ruby's convention puts in each namespace:
# Resolvers::BaseResolver, Mutations::BaseMutation,
# Subscriptions::BaseSubscription and Types::BaseObject. The classes Lighthouse
# generates inherit from them, so what every class of a kind shares (a concern,
# graphql-ruby's base type hookups) is written once, in the base.
# graphql-ruby's `graphql:install` writes the first two and the last the same way.
#
# A base that already exists is never replaced, not even with --force: it holds
# the app's own code, and one written by graphql-ruby works as it is.
module Lighthouse::Generators::BaseClasses
  BASES = {
    queries: {
      name: 'BaseResolver',
      source: <<~RUBY
        # What every class resolving a Query field shares: Lighthouse resolves
        # Query.latestPosts to Resolvers::LatestPosts by convention, and every such
        # class inherits from this one. graphql-ruby's `graphql:install` writes the
        # same class.
        class BaseResolver < GraphQL::Schema::Resolver
        end
      RUBY
    },
    mutations: {
      name: 'BaseMutation',
      source: <<~RUBY
        # What every class resolving a Mutation field shares: Lighthouse resolves
        # Mutation.publishPost to Mutations::PublishPost by convention, and every such
        # class inherits from this one. The SDL declares the arguments, so it is a
        # plain GraphQL::Schema::Mutation; the GraphQL::Schema::RelayClassicMutation
        # graphql-ruby's `graphql:install` writes (one `input:` argument) works too.
        class BaseMutation < GraphQL::Schema::Mutation
        end
      RUBY
    },
    subscriptions: {
      name: 'BaseSubscription',
      source: <<~RUBY
        # What every class resolving a Subscription field shares. The concern is PHP
        # Lighthouse's model: every subscriber of a field gets every broadcast, and the
        # class's `filter?` decides who receives it. A subclass that defines
        # graphql-ruby's own `authorized?` or `update` keeps them, and `topic_by
        # :arguments` brings back graphql-ruby's exact-argument matching.
        class BaseSubscription < GraphQL::Schema::Subscription
          include Lighthouse::GraphQL::Subscription
        end
      RUBY
    },
    types: {
      name: 'BaseObject',
      source: <<~RUBY
        # What every type class shares. The schema builds the SDL's object types from
        # it (base_types' object:). A subclass that includes Lighthouse::GraphQL::Type
        # (Types::PostType) resolves fields of its type, such as Post.readingTime with
        # Types::PostType#reading_time. graphql-ruby's `graphql:install` writes the
        # same class.
        class BaseObject < GraphQL::Schema::Object
        end
      RUBY
    }
  }.freeze

  private

  # The base class name for `kind` (`BaseResolver`), or nil for a kind without one.
  def base_class_name(kind)
    BASES.dig(kind, :name)
  end

  # Write the base class of `kind` into `namespace`, unless its file exists.
  def write_base_class(kind, namespace)
    base = BASES[kind]
    return unless base

    path = base_class_path(kind, namespace)
    if File.exist?(File.join(destination_root, path))
      say_status :skip, "#{path} already exists", :yellow
    else
      create_file path, ruby_source(namespace.split('::'), base[:source])
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
