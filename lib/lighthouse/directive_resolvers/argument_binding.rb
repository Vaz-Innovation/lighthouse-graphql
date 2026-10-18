# frozen_string_literal: true

# What @bind(class:) puts in place of an argument's value: the record of a model
# whose `column` matches it (a list's records, for a list), eager-loading `with`;
# or what a class's `call(value, context)` returns. A value that matches nothing
# is a validation error on the argument, as PHP Lighthouse's, unless `optional`.
class Lighthouse::GraphQL::DirectiveResolvers::ArgumentBinding
  def initialize(directive, argument, field_def)
    @directive = directive
    @argument = argument
    @field_def = field_def
  end

  def bind(value, ctx)
    klass = Lighthouse::Support::ModelResolver.constantize(arg('class'))
    raise Lighthouse::DefinitionError, "@bind(class: #{arg('class').inspect}) on #{@argument.name} names no class." unless klass
    return call(klass, value, ctx) unless model?(klass)

    value.is_a?(Array) ? records(klass, value) : record(klass, value)
  end

  private

  def arg(name)
    Lighthouse::Support::DirectiveArgs.literal(@directive, name)
  end

  def model?(klass)
    defined?(::ActiveRecord::Base) && klass.is_a?(Class) && klass < ::ActiveRecord::Base
  end

  def call(klass, value, ctx)
    bound = (klass.respond_to?(:call) ? klass : klass.new).call(value, ctx)
    bound.nil? ? missing : bound
  end

  def scope(klass)
    with = Array(arg('with'))
    with.empty? ? klass.all : klass.preload(*Lighthouse::Support::Preload.associations(with))
  end

  def record(klass, value)
    scope(klass).find_by(column => value) || missing
  end

  def records(klass, values)
    found = scope(klass).where(column => values).index_by { |record| record.public_send(column).to_s }
    bound = values.map { |value| found[value.to_s] }
    bound.include?(nil) ? missing(bound) : bound
  end

  def column
    arg('column') || 'id'
  end

  def missing(partial = nil)
    return partial if arg('optional')

    raise Lighthouse::ValidationError.new(@field_def.name, @argument.name => ["The selected #{@argument.name} is invalid."])
  end
end
