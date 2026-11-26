# frozen_string_literal: true

# The SDL of the Apollo Federation spec's directives and of the types they
# take, under the names the schema's Link gives them. The subgraph declares
# none of them: what it uses is injected while the schema is built, as
# Lighthouse's own directives are, and left out of the SDL the gateway
# composes (Federation::Printer), which knows them from the link.
module Lighthouse::GraphQL::Federation::Definitions
  # Where @tag and @inaccessible may go.
  EVERYWHERE = 'FIELD_DEFINITION | OBJECT | INTERFACE | UNION | ARGUMENT_DEFINITION | SCALAR | ENUM | ENUM_VALUE | ' \
               'INPUT_OBJECT | INPUT_FIELD_DEFINITION'

  # Where the access-control directives (@authenticated, @requiresScopes, @policy) go.
  ACCESS = 'FIELD_DEFINITION | OBJECT | INTERFACE | SCALAR | ENUM'

  # By spec name: the definition, with %<name>s for the local name of each
  # spec directive and type it mentions. Federation 1 knows the first five.
  DIRECTIVES = {
    'key' => 'directive @%<key>s(fields: %<FieldSet>s!, resolvable: Boolean = true) repeatable on OBJECT | INTERFACE',
    'requires' => 'directive @%<requires>s(fields: %<FieldSet>s!) on FIELD_DEFINITION',
    'provides' => 'directive @%<provides>s(fields: %<FieldSet>s!) on FIELD_DEFINITION',
    'external' => 'directive @%<external>s on OBJECT | FIELD_DEFINITION',
    'extends' => 'directive @%<extends>s on OBJECT | INTERFACE',
    'tag' => "directive @%<tag>s(name: String!) repeatable on #{EVERYWHERE} | SCHEMA",
    'shareable' => 'directive @%<shareable>s repeatable on OBJECT | FIELD_DEFINITION',
    'inaccessible' => "directive @%<inaccessible>s on #{EVERYWHERE}",
    'override' => 'directive @%<override>s(from: String!, label: String) on FIELD_DEFINITION',
    'composeDirective' => 'directive @%<composeDirective>s(name: String!) repeatable on SCHEMA',
    'interfaceObject' => 'directive @%<interfaceObject>s on OBJECT',
    'authenticated' => "directive @%<authenticated>s on #{ACCESS}",
    'requiresScopes' => "directive @%<requiresScopes>s(scopes: [[%<Scope>s!]!]!) on #{ACCESS}",
    'policy' => "directive @%<policy>s(policies: [[%<Policy>s!]!]!) on #{ACCESS}",
    'context' => 'directive @%<context>s(name: String!) repeatable on INTERFACE | OBJECT | UNION',
    'fromContext' => 'directive @%<fromContext>s(field: %<ContextFieldValue>s) on ARGUMENT_DEFINITION',
    'cost' => 'directive @%<cost>s(weight: Int!) on ARGUMENT_DEFINITION | ENUM | FIELD_DEFINITION | INPUT_FIELD_DEFINITION | OBJECT | SCALAR',
    'listSize' => 'directive @%<listSize>s(assumedSize: Int, slicingArguments: [String!], sizedFields: [String!], ' \
                  'requireOneSlicingArgument: Boolean = true) on FIELD_DEFINITION'
  }.freeze

  V1_DIRECTIVES = %w[key requires provides external extends].freeze

  # The spec's scalars, by spec name.
  TYPES = %w[FieldSet Scope Policy ContextFieldValue].freeze

  # The link spec's own, which a Federation 2 schema uses to declare its links.
  LINK = {
    'link' => 'directive @link(url: String!, as: String, import: [link__Import], for: link__Purpose) repeatable on SCHEMA'
  }.freeze

  LINK_TYPES = {
    'link__Import' => 'scalar link__Import',
    'link__Purpose' => <<~GRAPHQL.chomp
      enum link__Purpose {
        "`SECURITY` features provide metadata necessary to securely resolve fields."
        SECURITY
        "`EXECUTION` features provide metadata necessary for operation execution."
        EXECUTION
      }
    GRAPHQL
  }.freeze

  module_function

  # { local name => definition } of every spec directive the link knows.
  def directives(link)
    names = names(link)
    spec = link.v2? ? DIRECTIVES : DIRECTIVES.slice(*V1_DIRECTIVES)
    definitions = spec.to_h { |name, sdl| [link.directive(name), format(sdl, names)] }
    link.v2? ? definitions.merge(LINK) : definitions
  end

  # { local name => definition } of the spec's scalars (and the link spec's types).
  def types(link)
    scalars = TYPES.to_h { |name| [link.type(name), "scalar #{link.type(name)}"] }
    link.v2? ? scalars.merge(LINK_TYPES) : scalars.slice(link.type('FieldSet'))
  end

  # The local names of the spec's directives and types, as format's references.
  def names(link)
    directive_names = DIRECTIVES.keys.to_h { |name| [name.to_sym, link.directive(name)] }
    directive_names.merge(TYPES.to_h { |name| [name.to_sym, link.type(name)] })
  end
end
