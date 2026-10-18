# frozen_string_literal: true

# @complexity — what a field costs in a query's complexity score, the score
# graphql-ruby checks against the schema's `max_complexity` before it runs a
# query (GraphQL::Analysis::MaxQueryComplexity), as PHP Lighthouse does with
# webonyx's QueryComplexity rule.
#
# Lighthouse scores nothing itself: it gives fields their cost through
# graphql-ruby's `Field#complexity_for` hook, and graphql-ruby's analyzers add
# the costs up. A field costs:
#
# - With a bare @complexity, and on every paginated field (@paginate, and the
#   relationship directives given `type:`), 1 plus its selection's cost once per
#   item asked for (`first`, which defaults to the page size).
# - With @complexity(resolver: "Name"), the `complexity` the analyzer class
#   declares when it includes Lighthouse::GraphQL::ComplexityAnalyzer; else as
#   with a bare @complexity.
# - When a GraphQL::Schema::Resolver class resolves it (by convention, as
#   `Resolvers::Search` resolves `Query.search`, or through @field), the
#   `complexity` that class declares, as graphql-ruby gives `field ..., resolver:`.
# - Otherwise graphql-ruby's default: 1 plus its selection's cost.
#
# `resolver:` names a GraphQL::Analysis::Analyzer subclass, looked up in
# Config.namespaces[:analyzers] (`Analyzers::Name`). Lighthouse installs it on
# the schema, as graphql-ruby's `query_analyzer Analyzers::Name` would, so it
# runs on every query.
#
# Analyzer scores each query for BuildExtensionsResponse#query_complexity while
# something listens to that event.
module Lighthouse::GraphQL::Complexity
  DEFINITION = 'directive @complexity(resolver: String) on FIELD_DEFINITION'

  CONTEXT_KEY = :lighthouse_query_complexity

  module_function

  # Give the schema's fields their cost and install the analyzers @complexity
  # names (see above). `root_kinds` maps the root types' names to :queries /
  # :mutations / :subscriptions.
  def apply(schema, root_kinds = {})
    schema.types.each_value do |type|
      next unless type.kind.object? || type.kind.interface?

      type.fields.each_value do |field|
        calculator = calculator_for(schema, type, field, root_kinds[type.graphql_name])
        install(field, calculator) if calculator
      end
    end
    schema
  end

  # A query's score, once Analyzer has run on it; nil otherwise.
  def query_complexity(query)
    query.context[CONTEXT_KEY]
  end

  # graphql-ruby asks the field for its cost through `complexity_for`, which wins
  # over a number or proc in `complexity` and over its own scaling of connections.
  def install(field, calculator)
    field.define_singleton_method(:complexity_for) do |child_complexity:, query:, lookahead:|
      calculator.call(query.context, lookahead.arguments, child_complexity)
    end
  end

  # A callable (context, args, child_complexity) -> cost, or nil to leave the
  # field to graphql-ruby.
  def calculator_for(schema, type, field, kind)
    return unless field.ast_node

    directives = field.ast_node.directives || []
    directive = directives.find { |d| d.name == 'complexity' }
    return directive_calculator(schema, directive, "#{type.graphql_name}.#{field.name}") if directive
    return method(:per_item) if paginated?(directives)

    resolver_class_calculator(field, directives, kind)
  end

  def directive_calculator(schema, directive, path)
    name = Lighthouse::Support::DirectiveArgs.literal(directive, 'resolver')
    return method(:per_item) if name.nil? || name.to_s.strip.empty?

    analyzer = analyzer_class(name.to_s, path)
    schema.query_analyzer(analyzer) unless schema.query_analyzers.include?(analyzer)
    return method(:per_item) unless analyzer.include?(Lighthouse::GraphQL::ComplexityAnalyzer)

    lambda do |context, args, child_complexity|
      cost = analyzer.complexity
      cost.nil? ? per_item(context, args, child_complexity) : own_cost(cost, context, args, child_complexity)
    end
  end

  def analyzer_class(name, path)
    namespaces = Lighthouse::Config.namespaces[:analyzers]
    klass = Lighthouse::Support::ModelResolver.constantize(name, namespaces: namespaces)
    unless klass
      raise Lighthouse::DefinitionError,
            "@complexity on #{path}: no analyzer #{name} (looked up in #{Array(namespaces).join(', ')})"
    end
    return klass if klass.is_a?(Class) && klass < ::GraphQL::Analysis::Analyzer

    raise Lighthouse::DefinitionError, "@complexity on #{path}: #{klass} must inherit from GraphQL::Analysis::Analyzer"
  end

  # The field and its selection once per item asked for: PHP Lighthouse's
  # default, and what a page of `first` items costs.
  def per_item(_context, args, child_complexity)
    1 + (child_complexity * (args[:first] || 1))
  end

  # graphql-ruby's default cost: the field, plus its selection.
  def default_cost(child_complexity)
    1 + child_complexity
  end

  # A cost as graphql-ruby's Field#complexity takes it: a number, added to the
  # selection's, or a proc (context, args, child_complexity).
  def own_cost(cost, context, args, child_complexity)
    cost.respond_to?(:call) ? cost.call(context, args, child_complexity) : cost + child_complexity
  end

  def paginated?(directives)
    relations = Lighthouse::GraphQL::Directives::PaginationManipulator::RELATION_DIRECTIVES
    directives.any? do |d|
      d.name == 'paginate' || (relations.include?(d.name) && Lighthouse::Support::DirectiveArgs.literal(d, 'type'))
    end
  end

  # The `complexity` of the GraphQL::Schema::Resolver class that resolves the
  # field, by convention or through @field; nil when no such class can. The
  # class is looked up when a query is scored, so code reloading works.
  def resolver_class_calculator(field, directives, kind)
    lookup = resolver_class_lookup(field, directives, kind)
    return unless lookup

    lambda do |context, args, child_complexity|
      klass = lookup.call
      next default_cost(child_complexity) unless Lighthouse::GraphQL::ResolverDispatch.graphql_resolver?(klass)

      own_cost(klass.complexity, context, args, child_complexity)
    end
  end

  def resolver_class_lookup(field, directives, kind)
    directive = directives.find { |d| d.name == 'field' }
    return field_class_lookup(directive, kind) if directive
    return unless %i[queries mutations].include?(kind) && !Lighthouse::GraphQL::FieldResolverStack.resolving_directive?(directives)

    class_name = Lighthouse::GraphQL::DirectiveResolvers::ConventionResolver.class_name_for(field)
    -> { Lighthouse::Support::ModelResolver.constantize(class_name, namespaces: Lighthouse::Config.namespaces[kind], fallback: false) }
  end

  # The class @field names, looked up as @field looks it up.
  def field_class_lookup(directive, kind)
    class_name = %w[resolver class].filter_map { |name| Lighthouse::Support::DirectiveArgs.literal(directive, name) }.first
    return unless class_name

    namespaces = kind ? Lighthouse::Config.namespaces[kind] : Lighthouse::Config.resolver_namespaces
    -> { Lighthouse::Support::ModelResolver.constantize(class_name, namespaces: namespaces) }
  end

  # Scores each query as graphql-ruby's MaxQueryComplexity scores it against
  # `max_complexity`, for BuildExtensionsResponse#query_complexity. Runs only
  # while something listens to that event.
  class Analyzer < ::GraphQL::Analysis::QueryComplexity
    def analyze?
      Lighthouse::Events.listening?(Lighthouse::Events::BuildExtensionsResponse)
    end

    def result
      query.context[CONTEXT_KEY] = max_possible_complexity
      nil
    end
  end
end
