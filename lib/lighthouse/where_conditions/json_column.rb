# frozen_string_literal: true

# A column with a path into its JSON document, as Laravel names one and PHP
# Lighthouse's @whereConditions and @orderBy take it: `meta->tags`,
# `posts.meta->author->name`, `meta->tags->0` (an array index). The value at
# the path is compiled for the database, as Laravel's query grammars do:
#
#   PostgreSQL  "posts"."meta"->'author'->>'name'
#   MySQL       JSON_UNQUOTE(JSON_EXTRACT(`posts`.`meta`, '$."author"."name"'))
#   SQLite      json_extract("posts"."meta", '$."author"."name"')
#
# Unlike Laravel, it compares numbers and booleans as such, and orders by the
# JSON value (numbers numerically), on every database. The result is an Arel
# node: a condition calls its predicates (`eq`, `in`, `matches`, ...) and an
# order its `asc` / `desc`.
module Lighthouse::WhereConditions::JsonColumn
  PATH = /\A(?:(?<table>[A-Za-z_]\w*)\.)?(?<column>[A-Za-z_]\w*)(?<path>(?:->[A-Za-z0-9_-]+)+)\z/

  module_function

  def json?(name)
    name.to_s.include?('->')
  end

  def valid?(name)
    PATH.match?(name.to_s)
  end

  # The value at the path, as `as` says: :text, :numeric, :boolean, :null (NULL
  # when the path is missing or holds JSON null), or :sort (the JSON value,
  # ordered by type, numbers numerically).
  def node(klass, name, as: :text)
    match = PATH.match(name.to_s) or raise ArgumentError, "not a JSON column: #{name}"
    connection = klass.connection
    target = [match[:table] || klass.table_name, match[:column]].then do |table, column|
      "#{connection.quote_table_name(table)}.#{connection.quote_column_name(column)}"
    end
    segments = match[:path].split('->').drop(1)

    ::Arel.sql(public_send(dialect(connection), target, segments, as))
  end

  # How a condition with `operator` compares the value at the path: patterns as
  # text, nulls as JSON null too, the rest as the value is.
  def compared_as(operator, value)
    case operator
    when 'LIKE', 'NOT_LIKE' then :text
    when 'IS_NULL', 'IS_NOT_NULL' then :null
    else kind_of_value(value)
    end
  end

  # What a value compares as: numbers as numbers, booleans as booleans, the rest as text.
  def kind_of_value(value)
    sample = value.is_a?(Array) ? value.first : value
    case sample
    when Numeric then :numeric
    when true, false then :boolean
    else :text
    end
  end

  def dialect(connection)
    case connection.adapter_name
    when /postg/i then :postgresql
    when /mysql|trilogy/i then :mysql
    else :sqlite
    end
  end

  def postgresql(target, segments, as)
    keys = segments.map { |segment| segment.match?(/\A\d+\z/) ? segment : "'#{segment}'" }
    return "(#{target}->#{keys.join('->')})::jsonb" if as == :sort

    text = keys.size == 1 ? "#{target}->>#{keys.first}" : "#{target}->#{keys[0...-1].join('->')}->>#{keys.last}"
    { numeric: "(#{text})::numeric", boolean: "(#{text})::boolean" }.fetch(as, text) # :text, :null
  end

  def mysql(target, segments, as)
    extract = "JSON_EXTRACT(#{target}, '#{json_path(segments)}')"
    case as
    when :text then "JSON_UNQUOTE(#{extract})"
    when :numeric then "CAST(JSON_UNQUOTE(#{extract}) AS DECIMAL(65, 10))"
    when :boolean then "(#{extract} = CAST('true' AS JSON))"
    when :null then "NULLIF(JSON_TYPE(#{extract}), 'NULL')"
    else extract
    end
  end

  # json_extract answers SQLite's own types: numbers compare and order as numbers,
  # booleans are 1 and 0.
  def sqlite(target, segments, _as)
    "json_extract(#{target}, '#{json_path(segments)}')"
  end

  def json_path(segments)
    "$#{segments.map { |segment| segment.match?(/\A\d+\z/) ? "[#{segment}]" : %(."#{segment}") }.join}"
  end
end
