# frozen_string_literal: true

# A count a setting holds (Config.defer_max_nested_fields, defer_max_execution_ms): an Integer
# of 0 or more, or a String of digits (as ENV holds one) read as its number; anything else
# raises ArgumentError as the setting is assigned, not as a request runs.
module Lighthouse::Support::Count
  module_function

  # `value` as the setting `name` holds it; nil (the setting's default) as it is.
  def read(name, value)
    value = Integer(value.strip, 10) if value.is_a?(String) && value.strip.match?(/\A\d+\z/)
    return value if value.nil? || (value.is_a?(Integer) && !value.negative?)

    raise ArgumentError, "Lighthouse::Config.#{name} must be an Integer of 0 or more, got #{value.inspect}."
  end
end
