# frozen_string_literal: true

require_relative 'base'

module Lighthouse::GraphQL::Directives::Arguments
  # @whereNull — `true` keeps the rows whose column is null, `false` those whose
  # column is not. `posts(unpublished: Boolean @whereNull(key: "published_at"))`
  class WhereNull < Base
    def self.directive_name = 'whereNull'

    def self.definition
      <<~GRAPHQL.chomp
        """
        Filter the value is null: true keeps the rows where the column is null, false the others.
        """
        directive @whereNull(
          "The database column. Defaults to the argument's name."
          key: String
        ) on ARGUMENT_DEFINITION | INPUT_FIELD_DEFINITION
      GRAPHQL
    end

    def handle_builder(relation, value)
      return relation if value.nil?

      value ? relation.where(column => nil) : relation.where.not(column => nil)
    end
  end

  # @whereNotNull — the inverse: `true` keeps the rows whose column is not null.
  class WhereNotNull < Base
    def self.directive_name = 'whereNotNull'

    def self.definition
      <<~GRAPHQL.chomp
        """
        Filter the value is not null: true keeps the rows where the column is not null, false the others.
        """
        directive @whereNotNull(
          "The database column. Defaults to the argument's name."
          key: String
        ) on ARGUMENT_DEFINITION | INPUT_FIELD_DEFINITION
      GRAPHQL
    end

    def handle_builder(relation, value)
      return relation if value.nil?

      value ? relation.where.not(column => nil) : relation.where(column => nil)
    end
  end

  # @whereBetween — the column lies between two values: an input object's two
  # fields, in order, or a list of two. `createdAt: DateRange @whereBetween(key: "created_at")`
  class WhereBetween < Base
    def self.directive_name = 'whereBetween'

    def self.definition
      <<~GRAPHQL.chomp
        """
        Verify that a column's value is between two values: the argument's two input fields, in order.
        """
        directive @whereBetween(
          "The database column. Defaults to the argument's name."
          key: String
        ) on ARGUMENT_DEFINITION | INPUT_FIELD_DEFINITION
      GRAPHQL
    end

    def handle_builder(relation, value)
      from, to = bounds(value)
      return relation if from.nil? && to.nil?

      relation.where(column => from..to)
    end

    private

    def bounds(value)
      values = value.respond_to?(:to_h) && !value.is_a?(Array) ? value.to_h.values : Array(value)
      values.first(2)
    end
  end

  # @whereNotBetween — the column lies outside two values.
  class WhereNotBetween < WhereBetween
    def self.directive_name = 'whereNotBetween'

    def self.definition
      <<~GRAPHQL.chomp
        """
        Verify that a column's value lies outside two values: the argument's two input fields, in order.
        """
        directive @whereNotBetween(
          "The database column. Defaults to the argument's name."
          key: String
        ) on ARGUMENT_DEFINITION | INPUT_FIELD_DEFINITION
      GRAPHQL
    end

    def handle_builder(relation, value)
      from, to = bounds(value)
      return relation if from.nil? && to.nil?

      relation.where.not(column => from..to)
    end
  end

  # @whereJsonContains — a JSON column contains the value (Laravel's
  # whereJsonContains), on PostgreSQL (@>), MySQL (JSON_CONTAINS) and SQLite
  # (json_each). `key:` may point into the document: "options->tags".
  class WhereJsonContains < Base
    def self.directive_name = 'whereJsonContains'

    def self.definition
      <<~GRAPHQL.chomp
        """
        Use an input value as a whereJsonContains filter.
        """
        directive @whereJsonContains(
          "The JSON column, optionally with a path into it: \\"options->tags\\". Defaults to the argument's name."
          key: String
        ) on ARGUMENT_DEFINITION | INPUT_FIELD_DEFINITION
      GRAPHQL
    end

    def handle_builder(relation, value)
      return relation if value.nil?

      connection = relation.connection
      name, *path = column.to_s.split('->')
      target = "#{connection.quote_table_name(relation.klass.table_name)}.#{connection.quote_column_name(name)}"
      relation.where(*condition(connection.adapter_name, target, path, value))
    end

    private

    def condition(adapter, target, path, value)
      json_path = "$#{path.map { |segment| ".#{segment}" }.join}"
      case adapter
      when /postg/i then ["(#{target}#{path.map { |segment| "->'#{segment}'" }.join})::jsonb @> ?::jsonb", value.to_json]
      when /mysql|trilogy/i then ["JSON_CONTAINS(#{target}, ?, ?)", value.to_json, json_path]
      else sqlite(target, json_path, value)
      end
    end

    # Every value of a list must be in the array, as JSON containment means.
    def sqlite(target, json_path, value)
      values = Array(value)
      sql = values.map { "EXISTS (SELECT 1 FROM json_each(#{target}, ?) WHERE json_each.value = ?)" }.join(' AND ')
      [sql, *values.flat_map { |item| [json_path, item] }]
    end
  end

  # @limit — the argument directive behind LimitResolver. Only `builder: true`
  # makes it one: a LIMIT on the field's query. Without it, LimitResolver cuts
  # the results instead.
  class Limit < Base
    def self.directive_name = 'limit'

    # Only with `builder: true`: otherwise LimitResolver cuts the results after.
    def self.changes_query?(directive_node) = Lighthouse::Support::DirectiveArgs.literal(directive_node, 'builder') == true

    def self.definition
      <<~GRAPHQL.chomp
        """
        Allow clients to specify the maximum number of results to return when used on an argument,
        or statically limit them when used on a field.

        By default, this directive does not influence the number of results the resolver queries internally,
        but limits how much of it is returned to clients. Use the `builder` argument to change this.
        """
        directive @limit(
          """
          You may set this to `true` if the field uses a query builder,
          then this directive will apply a LIMIT clause to it.
          Typically, this option should only be used for root fields,
          as it may cause wrong results with batched relation queries.
          """
          builder: Boolean = false
        ) on ARGUMENT_DEFINITION | FIELD_DEFINITION
      GRAPHQL
    end

    def handle_builder(relation, value)
      return relation unless value.is_a?(Integer) && Lighthouse::Support::DirectiveArgs.literal(@directive_node, 'builder')

      relation.limit(value)
    end
  end

  # @scope — call a model scope with the client's value.
  # `posts(trending: Boolean @scope)` calls Post.trending(value); `name:` names another scope.
  class Scope < Base
    def self.directive_name = 'scope'

    def self.definition
      <<~GRAPHQL.chomp
        """
        Adds a scope to the query builder.
        The scope method will receive the client-given value of the argument as its argument.
        """
        directive @scope(
          "The name of the scope. Defaults to the name of the argument."
          name: String
        ) on ARGUMENT_DEFINITION | INPUT_FIELD_DEFINITION
      GRAPHQL
    end

    def handle_builder(relation, value)
      return relation if value.nil?

      relation.public_send(
        Lighthouse::Support::DirectiveArgs.literal(@directive_node, 'name') || Lighthouse::Support::Naming.attribute(@arg_node.name), value
      )
    end
  end
end
