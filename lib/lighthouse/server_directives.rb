# frozen_string_literal: true

# Lighthouse's directives instruct the server. PHP Lighthouse's executable
# schema holds only the standard directives and those the SDL declares: its
# own are found by name (DirectiveLocator), never added to the schema.
# Lighthouse injects their definitions for graphql-ruby to build the schema
# (SchemaGenerator.inject_directive_definitions), so it checks every directive
# the SDL uses has one, and then takes them out of the built schema.
module Lighthouse::GraphQL::ServerDirectives
  Nodes = ::GraphQL::Language::Nodes

  # Where a client may use a directive: in an operation, not the schema.
  EXECUTABLE_LOCATIONS = %w[QUERY MUTATION SUBSCRIPTION FIELD FRAGMENT_DEFINITION FRAGMENT_SPREAD INLINE_FRAGMENT VARIABLE_DEFINITION].freeze

  # The lists of a definition whose members may carry directives.
  MEMBER_LISTS = %i[fields arguments values].freeze

  module_function

  # Every directive the document uses is built in, Lighthouse's or declared;
  # else a DefinitionError naming it and where, as PHP Lighthouse's
  # DirectiveLocator raises. graphql-ruby fails too, but on a root type with a
  # NoMethodError from inside its builder.
  def check_defined!(document)
    defined = ::GraphQL::Schema.default_directives.keys.to_set
    definitions = document.definitions.group_by { |node| node.is_a?(Nodes::DirectiveDefinition) }
    (definitions[true] || []).each { |node| defined << node.name }

    each_member(definitions[false] || []) do |node, owner|
      unknown = node.directives.find { |directive| defined.exclude?(directive.name) }
      raise Lighthouse::DefinitionError, "No directive found for `@#{unknown.name}` on #{owner}." if unknown
    end
  end

  # Each definition, and each of its fields, arguments, values and input
  # fields at any depth, with its path (`Query.posts.first`).
  def each_member(definitions)
    stack = definitions.map { |node| [node, node.try(:name) || 'schema'] }
    while (entry = stack.pop)
      node, owner = entry
      yield node, owner
      MEMBER_LISTS.each do |list|
        node.public_send(list).each { |child| stack << [child, "#{owner}.#{child.name}"] } if node.respond_to?(list)
      end
    end
  end

  # Take Lighthouse's directives out of the built schema: clients see none
  # of them, in introspection or the printed schema (definitions, uses, nor
  # the types only they use), and an operation using one is invalid.
  # Lighthouse reads them from the SDL's nodes, not the schema. One a client
  # may use in an operation stays. Removed, not hidden: graphql-ruby only
  # checks `visible?` in a schema using GraphQL::Schema::Visibility.
  def hide!(schema, registry: Lighthouse::DirectiveRegistry.default)
    return unless schema.respond_to?(:own_directives, true)

    names = registry.directive_definitions.keys.to_set
    own = schema.send(:own_directives)
    own.delete_if do |name, directive|
      names.include?(name) && !directive.locations.map(&:to_s).intersect?(EXECUTABLE_LOCATIONS)
    end
  end
end
