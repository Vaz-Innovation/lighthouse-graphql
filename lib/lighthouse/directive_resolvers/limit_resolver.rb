# frozen_string_literal: true

require_relative 'base'

# @limit on an argument — the client caps how many results the field returns,
# as PHP Lighthouse's directive: `posts(limit: Int @limit): [Post!]! @all`. The
# argument must be an Int; null leaves the results alone. A query not run yet
# gets a LIMIT; a list already loaded (a @hasMany's records, loaded for every
# parent at once) is cut in memory, so one parent's limit never cuts another's.
# With `builder: true` it is a LIMIT on the field's query instead, through the
# argument directives (Arguments::Limit): for root fields, as PHP Lighthouse
# warns, since a relation batched for many parents would be cut as a whole.
# PHP Lighthouse also allows @limit on the field, where it marks the field the
# argument limits; it is accepted there and changes nothing. Not a directive
# resolver: FieldResolverStack installs it on a field whose arguments carry
# @limit, around whatever resolves the field.
class Lighthouse::GraphQL::DirectiveResolvers::LimitResolver < Lighthouse::GraphQL::DirectiveResolvers::BaseDirectiveResolver
  # The keyword of the argument whose @limit cuts the results, or nil; every
  # argument carrying @limit must be an Int.
  def self.keyword(field_def)
    limiting = field_def.arguments.each_value.select { |argument| directive(argument) }
    limiting.each { |argument| validate!(field_def, argument) }
    limiting.find { |argument| !Lighthouse::Support::DirectiveArgs.literal(directive(argument), 'builder') }&.keyword
  end

  def self.directive(argument)
    (argument.ast_node&.directives || []).find { |d| d.name == 'limit' }
  end

  def self.validate!(field_def, argument)
    return if argument.type.unwrap.graphql_name == 'Int'

    raise Lighthouse::DefinitionError,
          "The @limit directive must only be used on arguments of type Int, got #{field_def.name}.#{argument.graphql_name} of type " \
          "#{argument.type.unwrap.graphql_name}."
  end

  def define_resolver(target_type_class)
    keyword = self.class.keyword(@field_def)
    inner = capture_inner(target_type_class)

    install(target_type_class, lambda do |obj, args, ctx|
      limit = args.is_a?(Hash) ? args[keyword] : nil
      result = inner.call(obj, args, ctx)
      limit.nil? ? result : Lighthouse::GraphQL::DirectiveResolvers::LimitResolver.cut(result, limit)
    end)
  end

  def self.cut(result, limit)
    raise ::GraphQL::ExecutionError, "The limit must be positive, got #{limit}." if limit.negative?

    case result
    when ::ActiveRecord::Associations::CollectionProxy then result.to_a.first(limit)
    when ::ActiveRecord::Relation then result.loaded? ? result.to_a.first(limit) : result.limit(limit)
    when Array then result.first(limit)
    else result
    end
  end
end
