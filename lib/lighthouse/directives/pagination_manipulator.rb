# frozen_string_literal: true

require_relative 'pagination_info_types'

# Schema side of pagination, as PHP Lighthouse does it: a list field with
# @paginate — or a relation directive given `type:` — becomes a paginator
# or connection type, and gains its pagination arguments.
#
#   users: [User!]! @paginate                       -> users(first: Int!, page: Int): UserPaginator!
#   users: [User!]! @paginate(type: SIMPLE)         -> users(first: Int!, page: Int): UserSimplePaginator!
#   users: [User!]! @paginate(type: CONNECTION)     -> users(first: Int!, after: String): UserConnection!
#   posts: [Post!]! @hasMany(type: PAGINATOR)       -> posts(first: Int!, page: Int): PostPaginator!
#
# `first` defaults to the directive's defaultCount, else
# Config.pagination_default_count; without either it is required. A plain
# relation directive (no `type:`) and @all keep returning the list.
# The runtime side is Lighthouse::GraphQL::Pagination.
class Lighthouse::GraphQL::Directives::PaginationManipulator
  RELATION_DIRECTIVES = %w[hasMany hasManyThrough belongsToMany morphMany morphToMany].freeze
  OBJECT_DEFINITIONS = [
    ::GraphQL::Language::Nodes::ObjectTypeDefinition,
    ::GraphQL::Language::Nodes::ObjectTypeExtension
  ].freeze

  # Shared by every generated paginator/connection of the same kind.
  INFO_TYPES = Lighthouse::GraphQL::Directives::PaginationInfoTypes::DEFINITIONS

  def self.manipulate(sdl)
    return sdl unless sdl.is_a?(String) && sdl.match?(/@(paginate|#{RELATION_DIRECTIVES.join('|')})\b/)

    document = parse(sdl)
    return sdl unless document

    new(document, cache_control: sdl.gsub(/directive\s+@cacheControl/, '').include?('@cacheControl')).manipulate
  end

  def self.parse(sdl)
    ::GraphQL::Language::Parser.parse(sdl)
  rescue ::GraphQL::ParseError => e
    warn("Lighthouse pagination: parse failed: #{e.message}")
    nil
  end
  private_class_method :parse

  # With @cacheControl in use, the generated wrappers (paginatorInfo, data,
  # pageInfo, edges, node) take their parent's maxAge, as in PHP Lighthouse:
  # they are not entities of their own, so they must not turn a cacheable
  # page into `no-cache`.
  def initialize(document, cache_control: false)
    @document = document
    @inherit = cache_control ? ' @cacheControl(inheritMaxAge: true)' : ''
    @defined = document.definitions.filter_map { |d| d.name if d.respond_to?(:name) && !d.class.name.end_with?('Extension') }
    @generated = {}
  end

  def manipulate
    definitions = @document.definitions.map do |definition|
      next definition unless OBJECT_DEFINITIONS.any? { |kind| definition.is_a?(kind) }

      definition.merge(fields: definition.fields.map { |field| paginate_field(field) })
    end
    printed = ::GraphQL::Language::Printer.new.print(@document.merge(definitions: definitions))
    extra = @generated.except(*@defined).values
    ([printed] + extra).join("\n\n")
  end

  private

  def paginate_field(field)
    type = pagination_type(field.directives)
    item = type && list_item_type(field.type)
    return field unless item

    first = first_argument(field.directives)

    case type
    when 'CONNECTION'
      generate("#{item}Connection", connection_type(item))
      generate("#{item}Edge", edge_type(item))
      generate('PageInfo', INFO_TYPES['PageInfo'])
      rewrite(field, "#{item}Connection", first, 'after: String', 'A cursor after which elements are returned.')
    when 'SIMPLE'
      generate("#{item}SimplePaginator", paginator_type(item, 'SimplePaginator', 'SimplePaginatorInfo'))
      generate('SimplePaginatorInfo', INFO_TYPES['SimplePaginatorInfo'])
      rewrite(field, "#{item}SimplePaginator", first, 'page: Int', 'The offset from which items are returned.')
    else
      generate("#{item}Paginator", paginator_type(item, 'Paginator', 'PaginatorInfo'))
      generate('PaginatorInfo', INFO_TYPES['PaginatorInfo'])
      rewrite(field, "#{item}Paginator", first, 'page: Int', 'The offset from which items are returned.')
    end
  end

  # `first` defaults to the directive's defaultCount, else the configured
  # default; with neither it is required.
  def first_argument(directives)
    default_count = int_arg(directives, 'defaultCount') || Lighthouse::Config.pagination_default_count
    "first: Int!#{" = #{default_count}" if default_count}"
  end

  # The field returning `type_name!`, plus `first` and the page/cursor
  # argument, unless the field declares them itself.
  def rewrite(field, type_name, first, second, second_description)
    snippet = %(type T { f("Limits number of fetched items." #{first}, "#{second_description}" #{second}): #{type_name}! })
    generated = ::GraphQL::Language::Parser.parse(snippet).definitions.first.fields.first
    declared = field.arguments.map(&:name)
    arguments = field.arguments + generated.arguments.reject { |argument| declared.include?(argument.name) }
    field.merge(type: generated.type, arguments: arguments)
  end

  def generate(name, sdl)
    @generated[name] ||= sdl.strip
  end

  def paginator_type(item, suffix, info)
    <<~GRAPHQL
      "A paginated list of #{item} items."
      type #{item}#{suffix} {
        "Pagination information about the list of items."
        paginatorInfo: #{info}!#{@inherit}
        "A list of #{item} items."
        data: [#{item}!]!#{@inherit}
      }
    GRAPHQL
  end

  def connection_type(item)
    <<~GRAPHQL
      "A paginated list of #{item} edges."
      type #{item}Connection {
        "Pagination information about the list of edges."
        pageInfo: PageInfo!#{@inherit}
        "A list of #{item} edges."
        edges: [#{item}Edge!]!#{@inherit}
      }
    GRAPHQL
  end

  def edge_type(item)
    <<~GRAPHQL
      "An edge that contains a node of type #{item} and a cursor."
      type #{item}Edge {
        "The #{item} node."
        node: #{item}!#{@inherit}
        "A unique cursor that can be used for pagination."
        cursor: String!
      }
    GRAPHQL
  end

  # PAGINATOR / SIMPLE / CONNECTION, or nil when the field is not paginated.
  def pagination_type(directives)
    paginate = directives.find { |d| d.name == 'paginate' }
    return (Lighthouse::Support::DirectiveArgs.literal(paginate, 'type') || 'PAGINATOR').to_s.upcase if paginate

    relation_pagination_type(directives.find { |d| RELATION_DIRECTIVES.include?(d.name) })
  end

  # A relation directive paginates only when given `type:`.
  def relation_pagination_type(relation)
    relation && Lighthouse::Support::DirectiveArgs.literal(relation, 'type')&.to_s&.upcase
  end

  def int_arg(directives, name)
    directive = directives.find { |d| d.name == 'paginate' || RELATION_DIRECTIVES.include?(d.name) }
    directive && Lighthouse::Support::DirectiveArgs.literal(directive, name)
  end

  def list_item_type(type_node)
    type_node = type_node.of_type if type_node.is_a?(::GraphQL::Language::Nodes::NonNullType)
    return nil unless type_node.is_a?(::GraphQL::Language::Nodes::ListType)

    inner = type_node.of_type
    inner = inner.of_type while inner.respond_to?(:of_type)
    inner.name
  end
end
