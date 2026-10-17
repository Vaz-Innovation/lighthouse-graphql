# frozen_string_literal: true

require 'active_support/notifications'

# A small, framework-agnostic event dispatcher: PHP Lighthouse's events, which
# let an app hook into the request lifecycle and the schema build without
# patching either (see docs/events.md).
#
#   Lighthouse::Events.listen(Lighthouse::Events::BuildSchemaString) do |event|
#     'extend type Query { version: String }'
#   end
#
# A listener is anything that responds to `call(event)`. Every dispatch also
# goes through ActiveSupport::Notifications, as
# "<event name underscored>.lighthouse" (`start_execution.lighthouse`), with
# the event as the `:event` payload, so Rails tooling can observe them too.
module Lighthouse::Events
  # Base class of the events Lighthouse dispatches; a listener on it hears all
  # of them. Events that carry a time expose it as `moment`.
  class Event
    attr_reader :moment

    def initialize
      @moment = Time.now.utc
    end
  end

  @listeners = [].freeze
  @mutex = Mutex.new

  class << self
    # Register a listener (a callable or a block) for `event_class` and its
    # subclasses. Returns the listener, to hand to `forget`.
    def listen(event_class, callable = nil, &block)
      listener = callable || block
      raise ArgumentError, 'Lighthouse::Events.listen needs a callable or a block' unless listener.respond_to?(:call)

      @mutex.synchronize { @listeners = [*@listeners, [event_class, listener]].freeze }
      listener
    end

    # Unregister a listener (the value `listen` returned) from every event.
    def forget(listener)
      @mutex.synchronize { @listeners = @listeners.reject { |_, registered| registered.equal?(listener) }.freeze }
      nil
    end

    # Drop every listener (between specs).
    def reset!
      @mutex.synchronize { @listeners = [].freeze }
      nil
    end

    # Call the listeners of the event's class and its ancestors, in
    # registration order. Returns their non-nil return values; what a
    # return value means is up to the event.
    def dispatch(event)
      ::ActiveSupport::Notifications.instrument(notification_name(event.class), event: event) do
        @listeners.filter_map { |klass, listener| listener.call(event) if event.is_a?(klass) }
      end
    end

    # Whether dispatching an `event_class` event would reach anyone: a
    # listener, or an ActiveSupport::Notifications subscriber. Hot paths ask
    # first, to cost nothing when no one listens.
    def listening?(event_class)
      @listeners.any? { |klass, _| event_class <= klass } ||
        ::ActiveSupport::Notifications.notifier.listening?(notification_name(event_class))
    end

    # The ActiveSupport::Notifications name an event class is instrumented as.
    def notification_name(event_class)
      "#{(event_class.name || 'event').demodulize.underscore}.lighthouse"
    end
  end
end
