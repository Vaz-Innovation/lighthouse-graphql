# frozen_string_literal: true

require 'rails/generators'
require 'lighthouse-graphql'

module Lighthouse
  module Generators
    # Base for the generators that scaffold the classes a schema refers to by
    # name — queries, mutations, builders and validators — each in its own
    # namespace (Config.namespaces) and with its own contract.
    class ClassGenerator < ::Rails::Generators::NamedBase
      hide!

      class_option :namespace, type: :string,
                               desc: 'Namespace to generate into (default: the first of Config.namespaces for this kind)'

      def create_class
        create_file File.join('app/graphql', *modules.map(&:underscore), "#{class_basename.underscore}.rb"), source
      end

      def show_usage
        say_status :usage, usage, :blue if usage
      end

      private

      # :queries, :mutations, :builders or :validators.
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
        lines = ['# frozen_string_literal: true', '']
        modules.each_with_index { |mod, depth| lines << "#{'  ' * depth}module #{mod}" }
        body.each_line { |line| lines << (line.strip.empty? ? '' : "#{'  ' * modules.size}#{line.chomp}") }
        modules.size.times.reverse_each { |depth| lines << "#{'  ' * depth}end" }
        "#{lines.join("\n")}\n"
      end
    end
  end
end
