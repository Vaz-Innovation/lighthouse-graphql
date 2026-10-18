# frozen_string_literal: true

require 'rails/generators'
require 'lighthouse-graphql'
require_relative 'base_classes'

# Base for the generators that scaffold the classes a schema refers to by
# name — resolvers, mutations, subscriptions, builders and validators — each in
# its own namespace (Config.namespaces) and with its own contract. A resolver,
# mutation or subscription inherits from its namespace's base class
# (Resolvers::BaseResolver, ...), written first when it is missing.
class Lighthouse::Generators::ClassGenerator < Rails::Generators::NamedBase
  include Lighthouse::Generators::BaseClasses

  hide!

  class_option :namespace, type: :string,
                           desc: 'Namespace to generate into (default: the first of Config.namespaces for this kind)'

  def create_base_class
    write_base_class(kind, namespace_name)
  end

  def create_class
    create_file File.join('app/graphql', *modules.map(&:underscore), "#{class_basename.underscore}.rb"), source
  end

  def show_usage
    say_status :usage, usage, :blue if usage
  end

  private

  # :queries, :mutations, :subscriptions, :builders or :validators.
  def kind
    raise NotImplementedError
  end

  def body
    raise NotImplementedError
  end

  def usage
    nil
  end

  def class_basename
    class_name.demodulize
  end

  def namespace_name
    options[:namespace] || Lighthouse::Config.namespaces[kind].first
  end

  def modules
    namespace_name.split('::') + class_name.split('::')[0...-1]
  end

  def full_class_name
    (modules + [class_basename]).join('::')
  end

  def source
    ruby_source(modules, body)
  end

  # The class a generated class inherits from: the namespace's base class,
  # which Ruby finds from inside the namespace's modules.
  def superclass_name
    base_class_name(kind)
  end
end
