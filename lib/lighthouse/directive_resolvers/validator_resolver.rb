# frozen_string_literal: true

require_relative 'base'

# @validator — validate arguments with a contract class before the field
# resolves, as PHP Lighthouse's validator classes do.
#
#   type Mutation { updateUser(id: ID!, name: String): User @update @validator }
#   input CreatePostInput @validator { title: String }
#
# On a field, the contract gets all the field's arguments; the class
# defaults to Validators::<ParentType>::<FieldName>Validator. On an input
# type it gets that input's values wherever the type is used — nested,
# and per item of a list — defaulting to Validators::<InputType>Validator.
# Classes are looked up in Config.namespaces[:validators].
#
# A contract is a Dry::Validation::Contract (values arrive with
# snake_case symbol keys; declare `option :graphql_context` to receive the
# GraphQL context), or any object whose `call(values)` returns such a
# result or a { key => [messages] } Hash. Failures raise one
# Lighthouse::ValidationError keyed by GraphQL argument path.
#
# Model validations need no directive: @create/@update report them the
# same way. Use @validator for rules that are not the model's — checks
# across arguments, arguments of a query, or input that never reaches a model.
class Lighthouse::GraphQL::DirectiveResolvers::ValidatorDirectiveResolver < Lighthouse::GraphQL::DirectiveResolvers::BaseDirectiveResolver
  def self.directive_name = 'validator'
  def self.definition = 'directive @validator(class: String) on FIELD_DEFINITION | INPUT_OBJECT'

  # A default name, e.g. Mutation::SignUpValidator: always looked up under
  # the validators namespaces, although it contains `::`.
  Conventional = Struct.new(:name) do
    def to_s = name
  end

  # One validation of a field: the GraphQL context the contracts receive,
  # and the messages collected so far, keyed by argument path.
  Pass = Struct.new(:ctx, :messages)

  # Does any input type the field takes (at any depth) carry @validator?
  def self.input_validators?(field_def, seen = Set.new)
    field_def.arguments.each_value.any? do |argument|
      type = argument.type.unwrap
      next false unless type.kind.input_object? && seen.add?(type.graphql_name)

      validator_directive(type) || input_validators?(type, seen)
    end
  end

  def self.validator_directive(type)
    type.ast_node&.directives&.find { |d| d.name == 'validator' }
  end

  def define_resolver(target_type_class)
    me = self
    field_contract =
      (directive_arg('class') || Conventional.new("#{@type_def.graphql_name}::#{@field_def.name.to_s.camelize}Validator") if @directive_node)
    inner = capture_inner(target_type_class)

    install(target_type_class, lambda do |obj, args, ctx|
      me.send(:validate!, field_contract, args, ctx)
      inner.call(obj, args, ctx)
    end)
  end

  protected

  def validate!(field_contract, args, ctx)
    values = Lighthouse::Support::Arguments.plain(args)
    pass = Pass.new(ctx, {})
    run(field_contract, values, [], @field_def.arguments, pass) if field_contract
    validate_inputs(@field_def.arguments, values, [], pass)
    raise Lighthouse::ValidationError.new(@field_def.name, pass.messages) unless pass.messages.empty?
  end

  def validate_inputs(argument_defs, values, prefix, pass)
    by_keyword = Lighthouse::Support::Arguments.keyword_index(argument_defs)
    values.each do |key, value|
      argument = by_keyword[key.to_sym]
      next if argument.nil? || value.nil?

      type = argument.type.unwrap
      next unless type.kind.input_object?

      input_items(value, prefix + [argument.graphql_name]).each do |item, item_path|
        validate_input(type, item, item_path, pass)
      end
    end
  end

  # One input object value: its own @validator contract, then its nested inputs.
  def validate_input(type, values, path, pass)
    directive = self.class.validator_directive(type)
    if directive
      name = Lighthouse::Support::DirectiveArgs.literal(directive, 'class') || Conventional.new("#{type.graphql_name}Validator")
      run(name, values, path, type.arguments, pass)
    end
    validate_inputs(type.arguments, values, path, pass)
  end

  def run(class_name, values, prefix, argument_defs, pass)
    contract = instantiate(validator_class(class_name), pass.ctx)
    errors = error_hash(contract.call(values))

    flatten(errors).each do |segments, list|
      path = (prefix + graphql_path(segments, argument_defs)).join('.')
      (pass.messages[path.empty? ? @field_def.name : path] ||= []).concat(list)
    end
  end

  private

  # A list value validates per item, its path extended by the index.
  def input_items(value, path)
    items = Lighthouse::Support::Arguments.list(value)
    return [[value, path]] unless items

    items.each_with_index.map { |item, i| [item, path + [i.to_s]] }
  end

  # A contract answers a { key => [messages] } Hash, or a Dry::Validation
  # result whose message set converts to one.
  def error_hash(result)
    return result if result.is_a?(Hash)
    return {} if result.respond_to?(:success?) && result.success?

    message_set = result.errors
    message_set.to_h
  end

  def validator_class(name)
    namespaces = Lighthouse::Config.namespaces[:validators]
    found =
      if name.is_a?(Conventional)
        namespaces.lazy.filter_map { |ns| Lighthouse::Support::ModelResolver.constantize("#{ns}::#{name}") }.first
      else
        Lighthouse::Support::ModelResolver.constantize(name, namespaces: namespaces)
      end
    found ||
      raise(Lighthouse::DefinitionError,
            "@validator on #{@type_def.graphql_name}.#{@field_def.name}: no validator class #{name} " \
            "in #{Lighthouse::Config.namespaces[:validators].join(', ')}")
  end

  def instantiate(klass, ctx)
    return klass unless klass.is_a?(Class)
    return klass.new(graphql_context: ctx) if dry_option?(klass, :graphql_context)

    klass.new
  end

  def dry_option?(klass, name)
    klass.respond_to?(:dry_initializer) && klass.dry_initializer.options.any? { |option| option.target == name }
  end

  # Dry's nested errors hash as [[key, ...], [messages]] pairs; base errors
  # use a nil key.
  def flatten(errors, prefix = [])
    errors.flat_map do |key, value|
      path = key.nil? ? prefix : prefix + [key]
      case value
      when Hash then flatten(value, path)
      when Array then flatten_messages(value, path)
      else [[path, [value.to_s]]]
      end
    end
  end

  # A key with both its own messages and nested ones comes as
  # [messages, { nested }].
  def flatten_messages(value, path)
    if value.length == 2 && value.first.is_a?(Array) && value.last.is_a?(Hash)
      [[path, value.first]] + flatten(value.last, path)
    else
      [[path, value.map(&:to_s)]]
    end
  end

  # Map snake_case contract keys back to the GraphQL argument names.
  def graphql_path(segments, argument_defs)
    defs = argument_defs
    segments.map do |segment|
      next segment.to_s if segment.is_a?(Integer)

      argument = Lighthouse::Support::Arguments.keyword_index(defs)[segment.to_sym]
      next segment.to_s.camelize(:lower) unless argument

      type = argument.type.unwrap
      defs = type.kind.input_object? ? type.arguments : {}
      argument.graphql_name
    end
  end
end
