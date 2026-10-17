# frozen_string_literal: true

# What @broadcast does once a mutation has resolved: trigger the subscription
# field on the schema's subscriptions backend (`schema.subscriptions.trigger`),
# inline or, when queued, in a Lighthouse::GraphQL::BroadcastJob. Also checks,
# when the schema is built, that every @broadcast names a Subscription field.
module Lighthouse::GraphQL::Broadcasting
  module_function

  # Broadcast `root` to the subscribers of the field `name`.
  def broadcast(schema, name, root, context, should_queue: nil)
    return unless backend?(schema, name)

    klass = subscription_class(schema, name)
    return unless triggerable?(schema, name, klass)

    arguments = klass.respond_to?(:trigger_arguments) ? klass.trigger_arguments(root, context) : {}
    scope = klass.respond_to?(:trigger_scope) ? klass.trigger_scope(root, context) : nil

    if should_queue.nil? ? Lighthouse::Config.queue_broadcasts : should_queue
      enqueue(schema, name, arguments, root, scope)
    else
      trigger(schema, name, arguments, root, scope)
    end
  end

  # Can a trigger of `klass` reach anybody? graphql-ruby delivers to the
  # subscribers whose arguments equal the trigger's. A class with exact-argument
  # topics (a plain GraphQL::Schema::Subscription, or topic_by :arguments) that
  # leaves `trigger_arguments` at the default `{}`, on a field with a required
  # argument, therefore never reaches a single subscriber: each of them passed
  # that argument. That is certain, so it is reported through Config.on_error
  # (raised in a test environment, logged otherwise) and nothing is triggered.
  # Arguments that are all optional are not reported: argument-less subscribers
  # do match `{}`, which can be exactly what the class wants.
  def triggerable?(schema, name, klass)
    field = subscription_field(schema, name)
    required = field ? required_arguments(field) : []
    return true if required.empty? || trigger_arguments_defined?(klass)

    Lighthouse::Config.handle_error(
      Lighthouse::DefinitionError.new(
        "@broadcast(subscription: #{name.inspect}) can reach nobody: #{klass} matches subscribers by exact arguments, " \
        "but #{field.owner.graphql_name}.#{field.name} requires #{required.map { |arg| arg.graphql_name.inspect }.join(', ')} " \
        'and the class defines no `self.trigger_arguments(root, context)` saying what to trigger with. ' \
        "Define it, e.g. `def self.trigger_arguments(root, _context) = { #{required.first.graphql_name.underscore}: root.id.to_s }`, " \
        'or include Lighthouse::GraphQL::Subscription for one topic per field, filtered by `filter?`.'
      )
    )
    false
  end

  # Does a trigger of `klass` need its own trigger_arguments to match anyone?
  # Not for the field-wide topic of a class including Lighthouse::GraphQL::Subscription.
  def trigger_arguments_defined?(klass)
    return true if klass < Lighthouse::GraphQL::Subscription && klass.topic_by == :field

    klass.respond_to?(:trigger_arguments) && klass.method(:trigger_arguments).owner != Lighthouse::GraphQL::Subscription::ClassMethods
  end

  def required_arguments(field)
    field.arguments.values.select { |arg| arg.type.non_null? && !arg.default_value? }
  end

  # Trigger the subscription now. Misuse (arguments the field does not take, a
  # missing scope) goes through Config.on_error.
  def trigger(schema, name, arguments, root, scope = nil)
    schema.subscriptions.trigger(name, arguments, root, scope: scope)
  rescue ::GraphQL::Subscriptions::InvalidTriggerError, ::GraphQL::Subscriptions::SubscriptionScopeMissingError => e
    Lighthouse::Config.handle_error(e)
  end

  def enqueue(schema, name, arguments, root, scope)
    if schema.name.nil?
      raise Lighthouse::DefinitionError,
            'A queued @broadcast reaches its schema by name, but this schema is anonymous: assign it to a constant ' \
            '(AppSchema = Lighthouse::GraphQL::RbLightHouse.get_schema).'
    end

    job = broadcast_job
    queue = Lighthouse::Config.broadcast_queue
    (queue ? job.set(queue: queue) : job).perform_later(schema.name, name, arguments, root, scope)
  end

  def broadcast_job
    Lighthouse::GraphQL::BroadcastJob
  rescue LoadError
    raise Lighthouse::DefinitionError, 'Queueing @broadcast needs ActiveJob: add the activejob gem, or set shouldQueue: false.'
  end

  # Is there a backend to trigger? Reported through Config.on_error when not.
  def backend?(schema, name)
    return true if schema.subscriptions

    Lighthouse::Config.handle_error(
      Lighthouse::DefinitionError.new(
        "@broadcast(subscription: #{name.inspect}) has nowhere to broadcast: #{schema.name || 'the schema'} has no subscriptions backend. " \
        'Install one, e.g. `use GraphQL::Subscriptions::ActionCableSubscriptions`, or pass ' \
        '`options: { using: { GraphQL::Subscriptions::ActionCableSubscriptions => {} } }` to get_schema.'
      )
    )
    false
  end

  # The Subscription field called `name` (as written in the SDL or in
  # snake_case), or nil.
  def subscription_field(schema, name)
    fields = schema.subscription&.fields || {}
    fields[name.to_s] || fields[name.to_s.camelize(:lower)]
  end

  # The class the field stands for (see SubscriptionDirectiveResolver).
  def subscription_class(schema, name)
    subscription_field(schema, name)&.resolver || Lighthouse::GraphQL::Subscription::Default
  end

  # Every @broadcast in the schema must name a field of its Subscription type.
  def validate!(schema)
    schema.types.each_value do |type|
      next unless type.kind.object?

      type.fields.each_value do |field_def|
        broadcasts(field_def).each do |directive|
          name = Lighthouse::Support::DirectiveArgs.literal(directive, 'subscription')
          next if subscription_field(schema, name)

          raise Lighthouse::DefinitionError, unknown_subscription(schema, type, field_def, name)
        end
      end
    end
  end

  def broadcasts(field_def)
    (field_def.ast_node&.directives || []).select { |directive| directive.name == 'broadcast' }
  end

  def unknown_subscription(schema, type, field_def, name)
    where = "@broadcast on #{type.graphql_name}.#{field_def.name}"
    return "#{where}: the schema has no Subscription type, so there is no subscription #{name.inspect}." unless schema.subscription

    "#{where}: #{schema.subscription.graphql_name} has no field #{name.inspect}."
  end
end
