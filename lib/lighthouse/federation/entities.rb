# frozen_string_literal: true

# `Query._entities(representations:)`: the entities the gateway asks a subgraph
# for, by their keys: `[{ "__typename": "User", "id": "1" }, ...]`. As PHP
# Lighthouse's Entities and EntityResolverProvider, the representations are
# grouped by __typename and each group is resolved once, in order, by:
#
# 1. The type class, Types::<Name>Type including Lighthouse::GraphQL::Type, as
#    graphql-ruby's federation does it: `self.resolve_references(representations,
#    context)` for the group at once (an Array, in their order), or
#    `self.resolve_reference(representation, context)` for each.
# 2. The type's model (@model(class:), else the model of its name), queried by
#    the first @key whose fields the representation has, as PHP Lighthouse does,
#    but in one query for the whole group. A key field with @globalId is
#    decoded; a nested selection (`@key(fields: "author { id }")`) joins the
#    association. The values the gateway sends for the type's @external fields
#    (those a @requires asks for) are set on each record.
# 3. The representation itself, for a type that has no model: its fields read
#    the representation's values, or are resolved by its type class.
#
# An entity interface (`interface Media @key(fields: "id")`, Federation 2.3) is
# looked up in the models of the types that implement it, in turn, and each
# record answers as the object type it resolves to (TypeResolution).
#
# A representation nothing is found for is null, as the spec allows.
module Lighthouse::GraphQL::Federation::Entities
  Nodes = ::GraphQL::Language::Nodes

  # The context key of { entity => object type }, for _Entity's resolve_type.
  TYPES = :lighthouse_federation_entity_types

  module_function

  def resolve(representations, context)
    schema = context.schema
    results = Array.new(representations.size)
    representations.each_with_index.group_by { |representation, _| typename(representation) }.each do |typename, entries|
      type = entity_type(schema, typename)
      unique = entries.map(&:first).uniq
      found = unique.zip(resolve_group(schema, type, unique, context)).to_h
      entries.each { |representation, index| results[index] = remember(schema, type, found[representation], context) }
    end
    results
  end

  # The object type `_Entity` resolves `object` to, when `_entities` returned it.
  def type_of(object, context)
    map = context[TYPES]
    map[object] if map
  end

  def typename(representation)
    name = representation['__typename'] || representation[:__typename]
    raise ::GraphQL::ExecutionError, 'Each representation must have a __typename.' if name.blank?

    name.to_s
  end

  def entity_type(schema, typename)
    type = schema.get_type(typename)
    return type if type && (type.kind.object? || type.kind.interface?)

    raise ::GraphQL::ExecutionError, "Unknown __typename `#{typename}`."
  end

  def resolve_group(schema, type, representations, context)
    klass = Lighthouse::GraphQL::Type.class_for(type.graphql_name, type.kind.interface? ? :interface : :object)
    return Array(klass.resolve_references(representations, context)) if klass.respond_to?(:resolve_references)
    return representations.map { |representation| klass.resolve_reference(representation, context) } if klass.respond_to?(:resolve_reference)

    return from_models(schema, type, representations, context) if type.kind.interface?

    model = Lighthouse::GraphQL::Directives::ModelDirective.model_for(type)
    return representations unless Lighthouse::Support::ModelResolver.model?(model)

    Lookup.new(schema, type, context).find(model, representations)
  end

  # An entity interface: each implementing type's model, in turn, for the
  # representations not found yet.
  def from_models(schema, interface, representations, context)
    found = {}
    lookup = Lookup.new(schema, interface, context)
    interface_models(schema, interface).each do |model|
      missing = representations.reject { |representation| found[representation] }
      next if missing.empty?

      missing.zip(lookup.find(model, missing)).each { |representation, record| found[representation] = record if record }
    end
    representations.map { |representation| found[representation] }
  end

  # The models of the types implementing an entity interface, in their order.
  def interface_models(schema, interface)
    models = schema.possible_types(interface).map { |type| Lighthouse::GraphQL::Directives::ModelDirective.model_for(type) }
    models = models.select { |model| Lighthouse::Support::ModelResolver.model?(model) }
    return models if models.any?

    raise ::GraphQL::ExecutionError,
          "Lighthouse can not resolve the entity interface #{interface.graphql_name}: none of its types has a model. " \
          "Define Types::#{interface.graphql_name}Type's resolve_reference(representation, context)."
  end

  # Keeps the object type of what was found, for the _Entity union.
  def remember(schema, type, object, context)
    return if object.nil?

    concrete = type.kind.object? ? type : Lighthouse::GraphQL::TypeResolution.resolve(schema, type, object, context)
    concrete, object = concrete if concrete.is_a?(Array)
    (context[TYPES] ||= {}.compare_by_identity)[object] = concrete
    object
  end

  # The records of a model for representations of `type`, by its keys.
  class Lookup
    def initialize(schema, type, context)
      @schema = schema
      @type = type
      @context = context
      @link = Lighthouse::GraphQL::Federation.schema_link(schema)
    end

    # The record for each representation, or nil, in their order.
    def find(model, representations)
      keyed = representations.map { |representation| [representation, key_for(representation)] }
      found = {}
      keyed.group_by(&:last).each do |selections, group|
        found.merge!(find_by_key(model, selections, group.map(&:first)))
      end
      representations.map { |representation| hydrate(found[representation], representation) }
    end

    private

    # The first @key whose fields the representation has, as PHP Lighthouse picks it.
    def key_for(representation)
      key = keys.find { |selections| satisfies?(selections, representation) }
      return key if key

      raise ::GraphQL::ExecutionError,
            "Representation does not satisfy any set of uniquely identifying keys: #{representation.to_h.to_json}"
    end

    # Each @key(fields:) of the type, parsed: its field selections.
    def keys
      @keys ||= (@type.ast_node&.directives || []).select { |d| d.name == @link.directive('key') }.map do |directive|
        fields = Lighthouse::Support::DirectiveArgs.literal(directive, 'fields').to_s
        ::GraphQL::Language::Parser.parse("{ #{fields} }").definitions.first.selections
      end
    end

    def satisfies?(selections, value)
      selections.all? do |selection|
        raise Lighthouse::DefinitionError, "@key on #{@type.graphql_name} may only select fields." unless selection.is_a?(Nodes::Field)

        nested = value.is_a?(Hash) ? value[selection.name] : nil
        next false if nested.nil?

        selection.selections.empty? || satisfies?(selection.selections, nested)
      end
    end

    # { representation => record } for representations sharing a key: one
    # query for them all when the key's fields are flat, one each otherwise.
    def find_by_key(model, selections, representations)
      return representations.index_with { |representation| find_one(model, selections, representation) } if nested?(selections)

      columns = selections.map { |selection| column(@type, selection.name) }
      rows = representations.index_with { |representation| key_row(selections, representation) }
      relation = rows.values.uniq.map { |row| model.where(columns.zip(row).to_h) }.reduce(:or)
      records = by_columns(Lighthouse::GraphQL::TypeAuthorization.scope_type(relation, @type, @context), columns)
      rows.transform_values { |row| records[row.map(&:to_s)] }
    end

    # The relation's records by the values of `columns`, as strings.
    def by_columns(relation, columns)
      relation.to_a.index_by { |record| columns.map { |column| record.public_send(column).to_s } }
    end

    # The representation's values of a flat key's fields, as the columns hold them.
    def key_row(selections, representation)
      selections.map { |selection| key_value(@type, selection, representation[selection.name]) }
    end

    def nested?(selections)
      selections.any? { |selection| selection.selections.any? }
    end

    def find_one(model, selections, representation)
      relation = Lighthouse::GraphQL::TypeAuthorization.scope_type(model.all, @type, @context)
      records = constrain(relation, @type, selections, representation).limit(2).to_a
      raise ::GraphQL::ExecutionError, 'The query returned more than one result.' if records.size > 1

      records.first
    end

    # `relation` constrained to the key's values; a nested selection joins its association.
    def constrain(relation, type, selections, values)
      selections.reduce(relation) do |scope, selection|
        attribute = column(type, selection.name)
        value = values[selection.name]
        next scope.where(attribute => key_value(type, selection, value)) if selection.selections.empty?

        join(scope, type, selection, attribute, value)
      end
    end

    # `scope` joined to the association a nested key selection names, constrained to its values.
    def join(scope, type, selection, attribute, value)
      association = scope.klass.reflect_on_association(attribute.to_sym)
      unless association
        raise Lighthouse::DefinitionError, "@key on #{type.graphql_name} selects #{selection.name}, which is no association of #{scope.klass}."
      end

      field_type = type.get_field(selection.name).type.unwrap
      scope.joins(association.name).merge(constrain(association.klass.all, field_type, selection.selections, value))
    end

    # A key field's value as the column holds it: a @globalId field's decoded.
    def key_value(type, selection, value)
      field = type.get_field(selection.name)
      return value unless field && directive?(field, 'globalId')

      Lighthouse::GraphQL::GlobalId.decode!(value, @context).last
    end

    # The attribute a field of `type` reads: its @rename's, else its name in snake_case.
    def column(type, name)
      field = type.get_field(name)
      rename = field&.ast_node&.directives&.find { |d| d.name == 'rename' }
      (rename && Lighthouse::Support::DirectiveArgs.literal(rename, 'attribute')) || Lighthouse::Support::Naming.attribute(name)
    end

    def directive?(field, name)
      (field.ast_node&.directives || []).any? { |d| d.name == name }
    end

    # The values the gateway sent for the type's @external fields (those a
    # @requires needs), set on the record, as PHP Lighthouse sets them.
    def hydrate(record, representation)
      return record if record.nil? || !@type.kind.object?

      external_fields.each do |field|
        next unless representation.key?(field.graphql_name)

        assign(record, column(@type, field.graphql_name), representation[field.graphql_name])
      end
      record
    end

    def external_fields
      external = @link.directive('external')
      type_external = (@type.ast_node&.directives || []).any? { |d| d.name == external }
      @type.fields.values.select { |field| type_external || directive?(field, external) }
    end

    # A column is written (not saved); anything else answers from the record.
    def assign(record, attribute, value)
      if record.respond_to?(:has_attribute?) && record.has_attribute?(attribute)
        record[attribute] = value
        record.clear_attribute_change(attribute) if record.respond_to?(:clear_attribute_change)
      else
        record.define_singleton_method(attribute) { value }
      end
    end
  end
end
